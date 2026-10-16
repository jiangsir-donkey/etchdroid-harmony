/*
 * Discovery and opening of USB Mass Storage devices.
 *
 * ArkTS replacement for libaums' UsbMassStorageDevice plus EtchDroid's
 * EtchDroidUsbMassStorageDevice wrapper. A device qualifies when it exposes an
 * interface with class 0x08 (mass storage), subclass 0x06 (SCSI transparent
 * command set) and protocol 0x50 (Bulk-Only Transport) with one bulk IN and one
 * bulk OUT endpoint.
 */

import { usbManager } from '@kit.BasicServicesKit';
import { Logger } from '../utils/Logger';
import {
  InitException,
  MissingDeviceException,
  MissingPermissionException,
  toError,
} from '../exceptions/Exceptions';
import { BulkOnlyTransport } from './BulkOnlyTransport';
import { errorText } from '../utils/ErrorText';
import { MediaNotInsertedException, ScsiBlockDevice } from './ScsiBlockDevice';

const LOG = new Logger('UsbMassStorageDevice');

export const USB_CLASS_MASS_STORAGE = 0x08;
export const MASS_STORAGE_SUBCLASS_SCSI = 0x06;
export const MASS_STORAGE_PROTOCOL_BOT = 0x50;

const TRANSFER_TYPE_BULK = 0x02;
const DIRECTION_IN = 0x80;

/** Formats a USB id the way upstream's vidpid helper does. */
function formatId(id: number): string {
  if (typeof id !== 'number') {
    return '0000';
  }
  let text = id.toString(16);
  while (text.length < 4) {
    text = `0${text}`;
  }
  return text;
}

/**
 * Reads a descriptor field that the platform may leave unset.
 *
 * A missing field is reported as an empty string rather than the literal
 * "undefined", which keeps the picker readable on devices that do not fill in the
 * manufacturer/product strings.
 */
function fieldText(value: string): string {
  return typeof value === 'string' ? value : '';
}

/** One usable LUN interface found on an attached USB device. */
export class UsbMassStorageDeviceDescriptor {
  /** usbManager device name, required for requestRight()/hasRight(). */
  readonly deviceName: string;
  /** Human-readable "manufacturer product". */
  readonly name: string;
  /** "vvvv:pppp". */
  readonly vidpid: string;
  readonly device: usbManager.USBDevice;
  readonly iface: usbManager.USBInterface;
  readonly inEndpoint: usbManager.USBEndpoint;
  readonly outEndpoint: usbManager.USBEndpoint;

  constructor(
    device: usbManager.USBDevice,
    iface: usbManager.USBInterface,
    inEndpoint: usbManager.USBEndpoint,
    outEndpoint: usbManager.USBEndpoint,
  ) {
    this.device = device;
    this.deviceName = fieldText(device.name);
    this.name = `${fieldText(device.manufacturerName)} ${fieldText(device.productName)}`.trim();
    this.vidpid = `${formatId(device.vendorId)}:${formatId(device.productId)}`;
    this.iface = iface;
    this.inEndpoint = inEndpoint;
    this.outEndpoint = outEndpoint;
  }

  /** A serializable copy that can cross page boundaries and be stored. */
  toDeviceInfo(): DeviceInfo {
    const info = new DeviceInfo();
    info.deviceName = this.deviceName;
    info.name = this.name;
    info.vidpid = this.vidpid;
    info.vendorId = this.device.vendorId ?? 0;
    info.productId = this.device.productId ?? 0;
    info.manufacturerName = fieldText(this.device.manufacturerName);
    info.productName = fieldText(this.device.productName);
    info.serial = fieldText(this.device.serial);
    info.clazz = this.device.clazz ?? 0;
    info.subClass = this.device.subClass ?? 0;
    info.protocol = this.device.protocol ?? 0;
    return info;
  }

  /** True when `other` is the same physical device (survives reconnects). */
  matches(other: UsbMassStorageDeviceDescriptor): boolean {
    const a = this.device;
    const b = other.device;
    return a.vendorId === b.vendorId &&
      a.productId === b.productId &&
      a.manufacturerName === b.manufacturerName &&
      a.productName === b.productName &&
      a.clazz === b.clazz &&
      a.subClass === b.subClass &&
      a.protocol === b.protocol &&
      a.serial === b.serial;
  }
}

/**
 * A plain, serializable description of a mass-storage device.
 *
 * ArkTS router parameters and AppStorage values must be data, so pages hand each
 * other this snapshot instead of the live usbManager handle it is derived from.
 */
@Observed
export class DeviceInfo {
  deviceName: string = '';
  name: string = '';
  vidpid: string = '';
  vendorId: number = 0;
  productId: number = 0;
  manufacturerName: string = '';
  productName: string = '';
  serial: string = '';
  clazz: number = 0;
  subClass: number = 0;
  protocol: number = 0;
}

/** True when a currently attached device is the one `info` describes. */
export function deviceMatchesInfo(device: usbManager.USBDevice, info: DeviceInfo): boolean {
  return device.vendorId === info.vendorId &&
    device.productId === info.productId &&
    device.manufacturerName === info.manufacturerName &&
    device.productName === info.productName &&
    device.clazz === info.clazz &&
    device.subClass === info.subClass &&
    device.protocol === info.protocol &&
    device.serial === info.serial;
}

/** Re-resolves a stored DeviceInfo against the live device list. */
export function findMassStorageDevice(info: DeviceInfo): UsbMassStorageDeviceDescriptor | null {
  for (const descriptor of findMassStorageDevices()) {
    if (deviceMatchesInfo(descriptor.device, info)) {
      return descriptor;
    }
  }
  return null;
}

/**
 * Outcome of one USB scan.
 *
 * `usbAvailable` separates "nothing is plugged in" from "the USB host service
 * cannot be reached at all". The second case is normal on an emulator, which has no
 * USB passthrough, and the UI says so instead of waiting for a drive forever.
 */
export class MassStorageScan {
  devices: UsbMassStorageDeviceDescriptor[] = [];
  usbAvailable: boolean = true;
  failure: string = '';
}

/** Enumerates the host and keeps every mass-storage LUN it can understand. */
export function scanMassStorageDevices(): MassStorageScan {
  const scan = new MassStorageScan();

  let devices: usbManager.USBDevice[] | undefined | null = null;
  try {
    devices = usbManager.getDevices();
  } catch (error) {
    scan.usbAvailable = false;
    scan.failure = errorText(error);
    return scan;
  }

  // On a device without USB host support (an emulator, for instance) the native
  // layer logs "end call get device failed" and hands back no list at all instead
  // of throwing, so the missing list has to be checked for explicitly. Iterating it
  // would abort with a TypeError that looks nothing like a USB problem.
  if (devices === undefined || devices === null) {
    scan.usbAvailable = false;
    scan.failure = 'usbManager.getDevices() returned no device list';
    return scan;
  }

  for (const device of devices) {
    try {
      const configs: usbManager.USBConfiguration[] | undefined = device.configs;
      if (configs === undefined) {
        continue;
      }
      for (const config of configs) {
        const interfaces: usbManager.USBInterface[] | undefined = config.interfaces;
        if (interfaces === undefined) {
          continue;
        }
        for (const iface of interfaces) {
          const descriptor = describeInterface(device, iface);
          if (descriptor !== null) {
            scan.devices.push(descriptor);
          }
        }
      }
    } catch (error) {
      // A malformed descriptor for one device must not hide every other drive.
      scan.failure = errorText(error);
    }
  }
  return scan;
}

/** Every mass-storage LUN currently attached to the host. */
export function findMassStorageDevices(): UsbMassStorageDeviceDescriptor[] {
  return scanMassStorageDevices().devices;
}

/** Returns a descriptor when `iface` is a usable Bulk-Only SCSI interface. */
function describeInterface(
  device: usbManager.USBDevice,
  iface: usbManager.USBInterface,
): UsbMassStorageDeviceDescriptor | null {
  if (iface.clazz !== USB_CLASS_MASS_STORAGE ||
    iface.subClass !== MASS_STORAGE_SUBCLASS_SCSI ||
    iface.protocol !== MASS_STORAGE_PROTOCOL_BOT) {
    return null;
  }

  let bulkIn: usbManager.USBEndpoint | null = null;
  let bulkOut: usbManager.USBEndpoint | null = null;
  for (const endpoint of iface.endpoints) {
    if (endpoint.type !== TRANSFER_TYPE_BULK) {
      continue;
    }
    if (endpoint.direction === DIRECTION_IN) {
      bulkIn = endpoint;
    } else {
      bulkOut = endpoint;
    }
  }

  if (bulkIn === null || bulkOut === null) {
    LOG.warn(`Mass storage interface ${iface.id} on ${device.name} is missing a bulk endpoint pair`);
    return null;
  }
  return new UsbMassStorageDeviceDescriptor(device, iface, bulkIn, bulkOut);
}

/**
 * An opened mass storage device with its LUNs initialized.
 *
 * Upstream only ever writes to LUN 0, but initialization walks every LUN so that
 * multi-slot card readers do not silently shadow a populated slot.
 */
export class UsbMassStorageDevice {
  private readonly descriptor: UsbMassStorageDeviceDescriptor;
  private transport: BulkOnlyTransport | null = null;
  private blockDevices: ScsiBlockDevice[] = [];
  private opened: boolean = false;

  constructor(descriptor: UsbMassStorageDeviceDescriptor) {
    this.descriptor = descriptor;
  }

  get descriptorRef(): UsbMassStorageDeviceDescriptor {
    return this.descriptor;
  }

  /** LUN 0, the only unit EtchDroid writes to. */
  get primaryBlockDevice(): ScsiBlockDevice {
    if (this.blockDevices.length === 0) {
      throw new MissingDeviceException();
    }
    return this.blockDevices[0];
  }

  get isOpened(): boolean {
    return this.opened;
  }

  /**
   * Requests access, claims the interface and initializes every LUN.
   *
   * @throws MissingPermissionException when the user denies USB access
   * @throws InitException when no LUN carries usable media
   */
  async open(): Promise<void> {
    if (!usbManager.hasRight(this.descriptor.deviceName)) {
      let granted = false;
      try {
        granted = await usbManager.requestRight(this.descriptor.deviceName);
      } catch (error) {
        LOG.error(`requestRight failed: ${errorText(error)}`);
        granted = false;
      }
      if (!granted) {
        throw new MissingPermissionException();
      }
    }

    let pipe: usbManager.USBDevicePipe;
    try {
      pipe = usbManager.connectDevice(this.descriptor.device);
    } catch (error) {
      throw new InitException(
        'Failed to open the USB device',
        toError(error),
      );
    }

    // claimInterface with force=true mirrors upstream's libusb
    // detach-kernel-driver behaviour, needed for devices the host bound a driver to.
    const claimResult = usbManager.claimInterface(pipe, this.descriptor.iface, true);
    if (claimResult !== 0) {
      try {
        usbManager.closePipe(pipe);
      } catch (ignored) {
        // best effort
      }
      throw new InitException(`Failed to claim the mass storage interface (code ${claimResult})`);
    }

    const transport = new BulkOnlyTransport(
      pipe,
      this.descriptor.iface,
      this.descriptor.inEndpoint,
      this.descriptor.outEndpoint,
      this.descriptor.deviceName,
    );
    this.transport = transport;
    this.opened = true;

    const maxLun = await transport.getMaxLun();
    const units: ScsiBlockDevice[] = [];
    for (let lun = 0; lun <= maxLun; lun++) {
      const blockDevice = new ScsiBlockDevice(transport);
      try {
        await blockDevice.init();
        units.push(blockDevice);
      } catch (error) {
        if (error instanceof MediaNotInsertedException) {
          LOG.info(`LUN ${lun} has no media, skipping`);
          continue;
        }
        throw toError(error);
      }
    }

    if (units.length === 0) {
      await this.close();
      throw new InitException('No media is inserted in the USB drive');
    }
    this.blockDevices = units;
  }

  /**
   * Releases the interface claim and closes the pipe. Tolerates partially
   * initialized devices and repeated calls, so it is always safe in a finally block.
   */
  async close(): Promise<void> {
    this.opened = false;
    this.blockDevices = [];
    const transport = this.transport;
    this.transport = null;
    if (transport !== null) {
      try {
        await transport.close();
      } catch (error) {
        LOG.warn(`Failed to close USB transport: ${errorText(error)}`);
      }
    }
  }
}

/** Convenience wrapper matching upstream's helper of the same name. */
export function openMassStorageDevice(
  descriptor: UsbMassStorageDeviceDescriptor,
): UsbMassStorageDevice {
  return new UsbMassStorageDevice(descriptor);
}
