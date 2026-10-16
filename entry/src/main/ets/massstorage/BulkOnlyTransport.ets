/*
 * USB Mass Storage Bulk-Only Transport (BOT) over the HarmonyOS USB host API.
 *
 * This is the ArkTS replacement for libaums' UsbCommunication + ScsiBlockDevice
 * transport half. It frames SCSI commands into Command Block Wrappers, carries the
 * data phase over the bulk endpoints, and parses the Command Status Wrapper.
 *
 * HarmonyOS rejects a single bulkTransfer whose payload is 200 KB or larger, so
 * every phase is chunked through MAX_TRANSFER_CHUNK.
 */

import { usbManager, BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../utils/Logger';
import { UsbCommunicationException } from '../exceptions/Exceptions';
import * as Scsi from './Scsi';
import { errorText } from '../utils/ErrorText';

const LOG = new Logger('BulkOnlyTransport');

/**
 * Largest payload handed to usbManager.bulkTransfer in one call. The platform
 * rejects transfers of 200 KB or more, so 64 KiB keeps a wide margin while still
 * being a multiple of every block size we support (512 / 2048 / 4096).
 */
export const MAX_TRANSFER_CHUNK = 64 * 1024;

/**
 * Per-bulk-transfer timeout. Upstream passes 0 (wait forever) to libusb, which can
 * hang the app indefinitely on a wedged drive; a finite timeout lets the job fail
 * cleanly and surface a recoverable error instead.
 */
export const USB_TRANSFER_TIMEOUT_MS = 15000;

/** usbManager error code for "no such device (it may have been disconnected)". */
const ERR_NO_SUCH_DEVICE = 14400008;

/** Outcome of one BOT command, data phase and status phase. */
export class TransferOutcome {
  readonly residue: number;
  readonly status: number;

  constructor(residue: number, status: number) {
    this.residue = residue;
    this.status = status;
  }

  get isPassed(): boolean {
    return this.status === Scsi.CSW_STATUS_PASSED;
  }

  get isPhaseError(): boolean {
    return this.status === Scsi.CSW_STATUS_PHASE_ERROR;
  }
}

function isNoSuchDevice(error: Object): boolean {
  const code: number | undefined = (error as BusinessError).code;
  return code === ERR_NO_SUCH_DEVICE;
}

export class BulkOnlyTransport {
  private readonly pipe: usbManager.USBDevicePipe;
  private readonly iface: usbManager.USBInterface;
  private readonly inEndpoint: usbManager.USBEndpoint;
  private readonly outEndpoint: usbManager.USBEndpoint;
  private readonly deviceName: string;

  /** Rolling CBW tag; the CSW must echo it back. */
  private nextTag: number = 1;
  private closed: boolean = false;

  /** Scratch buffer for the status phase. */
  private readonly cswBuffer: Uint8Array = new Uint8Array(Scsi.CSW_LENGTH);

  constructor(
    pipe: usbManager.USBDevicePipe,
    iface: usbManager.USBInterface,
    inEndpoint: usbManager.USBEndpoint,
    outEndpoint: usbManager.USBEndpoint,
    deviceName: string,
  ) {
    this.pipe = pipe;
    this.iface = iface;
    this.inEndpoint = inEndpoint;
    this.outEndpoint = outEndpoint;
    this.deviceName = deviceName;
  }

  get isClosed(): boolean {
    return this.closed;
  }

  // -------------------------------------------------------------------------
  // Class-specific control requests
  // -------------------------------------------------------------------------

  /**
   * GET_MAX_LUN, used to count the logical units behind one mass-storage
   * interface. Devices that do not implement it are single-LUN by definition.
   */
  async getMaxLun(): Promise<number> {
    const data = new Uint8Array(1);
    const params: usbManager.USBDeviceRequestParams = {
      bmRequestType: Scsi.REQ_GET_MAX_LUN_TYPE,
      bRequest: Scsi.REQ_GET_MAX_LUN,
      wValue: 0,
      wIndex: this.iface.id,
      wLength: 1,
      data: data,
    };
    try {
      const transferred = await usbManager.usbControlTransfer(this.pipe, params, USB_TRANSFER_TIMEOUT_MS);
      if (transferred < 0) {
        LOG.warn('GET_MAX_LUN rejected, assuming a single LUN');
        return 0;
      }
      return data[0] & 0x0F;
    } catch (error) {
      LOG.warn(`GET_MAX_LUN failed (${errorText(error)}), assuming a single LUN`);
      return 0;
    }
  }

  /**
   * Bulk-Only Mass Storage Reset plus CLEAR_FEATURE(ENDPOINT_HALT) on both bulk
   * endpoints. This is the mandatory error-recovery sequence from the BOT spec.
   */
  async resetRecovery(): Promise<void> {
    try {
      await this.classRequest(Scsi.REQ_BOT_RESET_TYPE, Scsi.REQ_BOT_RESET, 0, this.iface.id, 0, new Uint8Array(0));
    } catch (error) {
      LOG.warn(`Bulk-Only Mass Storage Reset failed: ${errorText(error)}`);
    }
    await this.clearHalt(this.inEndpoint.address);
    await this.clearHalt(this.outEndpoint.address);
  }

  private async clearHalt(endpointAddress: number): Promise<void> {
    try {
      await this.classRequest(
        Scsi.REQ_CLEAR_FEATURE_TYPE,
        Scsi.REQ_CLEAR_FEATURE,
        Scsi.FEATURE_ENDPOINT_HALT,
        endpointAddress,
        0,
        new Uint8Array(0),
      );
    } catch (error) {
      LOG.warn(`CLEAR_FEATURE(HALT) on 0x${endpointAddress.toString(16)} failed: ${errorText(error)}`);
    }
  }

  private async classRequest(
    bmRequestType: number,
    bRequest: number,
    wValue: number,
    wIndex: number,
    wLength: number,
    data: Uint8Array,
  ): Promise<number> {
    const params: usbManager.USBDeviceRequestParams = {
      bmRequestType: bmRequestType,
      bRequest: bRequest,
      wValue: wValue,
      wIndex: wIndex,
      wLength: wLength,
      data: data,
    };
    return await usbManager.usbControlTransfer(this.pipe, params, USB_TRANSFER_TIMEOUT_MS);
  }

  // -------------------------------------------------------------------------
  // Bulk phases
  // -------------------------------------------------------------------------

  private async bulkTransfer(
    endpoint: usbManager.USBEndpoint,
    buffer: Uint8Array,
  ): Promise<number> {
    try {
      return await usbManager.bulkTransfer(this.pipe, endpoint, buffer, USB_TRANSFER_TIMEOUT_MS);
    } catch (error) {
      const noDevice = isNoSuchDevice(error as Object);
      throw new UsbCommunicationException(
        new Error(`Bulk transfer failed: ${errorText(error)}`),
        noDevice,
      );
    }
  }

  /** Sends a whole buffer out, continuing until every byte is on the wire. */
  private async sendAll(data: Uint8Array): Promise<void> {
    let offset = 0;
    while (offset < data.length) {
      const length = Math.min(MAX_TRANSFER_CHUNK, data.length - offset);
      const view = data.subarray(offset, offset + length);
      const written = await this.bulkTransfer(this.outEndpoint, view);
      if (written <= 0) {
        throw new UsbCommunicationException(new Error(`Bulk OUT stalled after ${offset} bytes (result ${written})`));
      }
      offset += written;
    }
  }

  /** Receives exactly `length` bytes into `target` starting at `offset`. */
  private async receiveAll(target: Uint8Array, offset: number, length: number): Promise<void> {
    let received = 0;
    while (received < length) {
      const wanted = Math.min(MAX_TRANSFER_CHUNK, length - received);
      const view = target.subarray(offset + received, offset + received + wanted);
      const read = await this.bulkTransfer(this.inEndpoint, view);
      if (read <= 0) {
        throw new UsbCommunicationException(
          new Error(`Bulk IN stalled after ${received} of ${length} bytes (result ${read})`),
        );
      }
      received += read;
    }
  }

  // -------------------------------------------------------------------------
  // Command execution
  // -------------------------------------------------------------------------

  /**
   * Runs one BOT transaction.
   *
   * @param cb the SCSI command descriptor block
   * @param data for a data-in command, the buffer to fill; for a data-out command,
   *             the payload to send; null for commands without a data phase
   * @param dataIn true when the data phase moves device to host
   * @returns the parsed command status
   */
  async execute(cb: Uint8Array, data: Uint8Array | null, dataIn: boolean): Promise<TransferOutcome> {
    if (this.closed) {
      throw new UsbCommunicationException(new Error('Transport is closed'));
    }

    const dataLength = data === null ? 0 : data.length;
    const tag = this.nextTag;
    this.nextTag = (this.nextTag + 1) >>> 0;
    if (this.nextTag === 0) {
      this.nextTag = 1;
    }

    const flags = dataIn ? Scsi.CBW_FLAGS_DATA_IN : Scsi.CBW_FLAGS_DATA_OUT;
    const cbw = new Scsi.CommandBlockWrapper(tag, dataLength, flags, 0, cb);
    await this.sendAll(cbw.toBytes());

    if (dataLength > 0 && data !== null) {
      if (dataIn) {
        await this.receiveAll(data, 0, dataLength);
      } else {
        await this.sendAll(data);
      }
    }

    await this.receiveAll(this.cswBuffer, 0, Scsi.CSW_LENGTH);
    const csw = Scsi.parseCommandStatusWrapper(this.cswBuffer, 0);

    if (!csw.isValid) {
      throw new UsbCommunicationException(new Error('Malformed Command Status Wrapper'));
    }
    if (csw.tag !== tag) {
      throw new UsbCommunicationException(new Error(`CSW tag mismatch: expected ${tag}, got ${csw.tag}`));
    }
    return new TransferOutcome(csw.dataResidue, csw.status);
  }

  // -------------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------------

  /** Releases the claimed interface and closes the device pipe. */
  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    try {
      usbManager.releaseInterface(this.pipe, this.iface);
    } catch (error) {
      LOG.warn(`Failed to release interface: ${errorText(error)}`);
    }
    try {
      usbManager.closePipe(this.pipe);
    } catch (error) {
      LOG.warn(`Failed to close pipe: ${errorText(error)}`);
    }
    LOG.info(`Closed USB device ${this.deviceName}`);
  }
}
