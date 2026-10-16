/*
 * SCSI transparent-command-set block device driver.
 *
 * ArkTS replacement for libaums' me.jahnen.libaums.core.driver.scsi.ScsiBlockDevice.
 * Exposes the same surface EtchDroid relies on: blockSize, blocks, read() and write().
 */

import { Logger } from '../utils/Logger';
import { InitException, UsbCommunicationException, UsbDriveTooLargeException } from '../exceptions/Exceptions';
import { BulkOnlyTransport, MAX_TRANSFER_CHUNK, TransferOutcome } from './BulkOnlyTransport';
import * as Scsi from './Scsi';

const LOG = new Logger('ScsiBlockDevice');

/** Fixed-format sense data is 18 bytes; ask for the standard 252-byte allocation. */
const REQUEST_SENSE_LENGTH = 252;

/**
 * Block count ceiling. Upstream EtchDroid documents that drives of 2 TB and above
 * are unsupported: at 512 bytes per block, 2 TB is exactly 2^32 blocks, the point
 * where the 32-bit logical block address in READ(10)/WRITE(10) wraps. Rejecting
 * such drives up front is far better than corrupting them silently.
 */
const MAX_SUPPORTED_BLOCKS = 0xFFFFFFFF;

const DEFAULT_BLOCK_SIZE = 512;
const VALID_BLOCK_SIZES: number[] = [512, 1024, 2048, 4096];

/** Attempts and delay used while waiting for a drive to spin up. */
const READY_RETRIES = 60;
const READY_RETRY_DELAY_MS = 100;

/** Raised when a LUN exists but has no media loaded; callers skip such LUNs. */
export class MediaNotInsertedException extends Error {
  constructor() {
    super('No media inserted in this logical unit');
    this.name = 'MediaNotInsertedException';
  }
}

export function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

function readUint64BE(source: Uint8Array, offset: number): number {
  const high = Scsi.readUint32BE(source, offset);
  const low = Scsi.readUint32BE(source, offset + 4);
  return high * 0x100000000 + low;
}

/** Block-oriented view of one LUN on a USB mass storage device. */
export class ScsiBlockDevice {
  private readonly transport: BulkOnlyTransport;

  private currentBlockSize: number = DEFAULT_BLOCK_SIZE;
  private currentBlocks: number = 0;
  private initialized: boolean = false;

  constructor(transport: BulkOnlyTransport) {
    this.transport = transport;
  }

  get blockSize(): number {
    return this.currentBlockSize;
  }

  get blocks(): number {
    return this.currentBlocks;
  }

  /** Total addressable size in bytes. */
  get sizeInBytes(): number {
    return this.currentBlocks * this.currentBlockSize;
  }

  get isInitialized(): boolean {
    return this.initialized;
  }

  // -------------------------------------------------------------------------
  // Initialization
  // -------------------------------------------------------------------------

  /**
   * Spins the unit up, reads its geometry and validates the drive against
   * EtchDroid's supported size range.
   *
   * @throws MediaNotInsertedException when the LUN has no media
   * @throws InitException when the unit never becomes ready
   * @throws UsbDriveTooLargeException when the drive exceeds the 2 TB limit
   */
  async init(): Promise<void> {
    await this.waitUntilReady();
    await this.readCapacity();

    if (this.currentBlocks <= 0) {
      throw new InitException('Device reports zero blocks');
    }
    if (this.currentBlocks > MAX_SUPPORTED_BLOCKS) {
      throw new UsbDriveTooLargeException();
    }

    this.initialized = true;
    LOG.info(`Initialized: ${this.currentBlocks} blocks of ${this.currentBlockSize} bytes ` +
      `(${this.sizeInBytes} bytes)`);
  }

  private async waitUntilReady(): Promise<void> {
    for (let attempt = 0; attempt < READY_RETRIES; attempt++) {
      const outcome = await this.transport.execute(Scsi.cdbTestUnitReady(), null, true);
      if (outcome.isPassed) {
        return;
      }
      const sense = await this.requestSense();
      if (sense.isMediumNotPresent) {
        throw new MediaNotInsertedException();
      }
      if (sense.isUnitAttention) {
        // Power-on / bus-reset / media-change notification: clear it and retry.
        await delay(READY_RETRY_DELAY_MS);
        continue;
      }
      await delay(READY_RETRY_DELAY_MS);
    }
    throw new InitException('Device did not become ready in time');
  }

  private async readCapacity(): Promise<void> {
    const response = new Uint8Array(8);
    const outcome = await this.transport.execute(Scsi.cdbReadCapacity10(), response, true);
    if (!outcome.isPassed) {
      await this.throwForSense('READ CAPACITY(10) failed');
    }

    let lastBlockAddress = Scsi.readUint32BE(response, 0);
    let blockLength = Scsi.readUint32BE(response, 4);

    if (lastBlockAddress === 0xFFFFFFFF) {
      const wide = new Uint8Array(32);
      const wideOutcome = await this.transport.execute(Scsi.cdbReadCapacity16(), wide, true);
      if (!wideOutcome.isPassed) {
        await this.throwForSense('READ CAPACITY(16) failed');
      }
      lastBlockAddress = readUint64BE(wide, 0);
      blockLength = Scsi.readUint32BE(wide, 8);
    }

    this.currentBlocks = lastBlockAddress + 1;
    this.currentBlockSize = this.normalizeBlockSize(blockLength);
  }

  /**
   * Devices that report an implausible or zero block length are assumed to use
   * the 512-byte default, which every USB mass storage device must support.
   */
  private normalizeBlockSize(reported: number): number {
    if (VALID_BLOCK_SIZES.indexOf(reported) >= 0) {
      return reported;
    }
    if (reported !== 0) {
      LOG.warn(`Device reported unusual block size ${reported}, falling back to ${DEFAULT_BLOCK_SIZE}`);
    }
    return DEFAULT_BLOCK_SIZE;
  }

  // -------------------------------------------------------------------------
  // Data transfers
  // -------------------------------------------------------------------------

  /**
   * Reads `buffer.length` bytes starting at logical block `blockNumber`.
   * The length must be a whole number of blocks.
   */
  async read(blockNumber: number, buffer: Uint8Array): Promise<void> {
    await this.transfer(false, blockNumber, buffer);
  }

  /**
   * Writes `buffer.length` bytes starting at logical block `blockNumber`.
   * The length must be a whole number of blocks.
   */
  async write(blockNumber: number, buffer: Uint8Array): Promise<void> {
    await this.transfer(true, blockNumber, buffer);
  }

  private async transfer(isWrite: boolean, blockNumber: number, buffer: Uint8Array): Promise<void> {
    if (!this.initialized) {
      throw new InitException('Block device used before init()');
    }
    if (buffer.length === 0) {
      return;
    }
    if (buffer.length % this.currentBlockSize !== 0) {
      throw new Error(`Transfer size ${buffer.length} is not a multiple of the block size ${this.currentBlockSize}`);
    }

    const blocksPerCommand = Math.max(1, Math.floor(MAX_TRANSFER_CHUNK / this.currentBlockSize));
    let remaining = buffer.length;
    let offset = 0;
    let currentBlock = blockNumber;

    while (remaining > 0) {
      const chunkBlocks = Math.min(blocksPerCommand, remaining / this.currentBlockSize);
      const chunkBytes = chunkBlocks * this.currentBlockSize;
      const view = buffer.subarray(offset, offset + chunkBytes);

      await this.executeWithRecovery(
        Scsi.cdbReadWrite(isWrite, currentBlock, chunkBlocks),
        view,
        !isWrite,
        isWrite ? 'WRITE' : 'READ',
      );

      offset += chunkBytes;
      remaining -= chunkBytes;
      currentBlock += chunkBlocks;
    }
  }

  /**
   * Runs one command, retrying once on unit attention and performing BOT reset
   * recovery on a phase error, matching the robustness of the upstream stack.
   */
  private async executeWithRecovery(
    cb: Uint8Array,
    data: Uint8Array | null,
    dataIn: boolean,
    what: string,
  ): Promise<TransferOutcome> {
    let outcome = await this.transport.execute(cb, data, dataIn);

    if (outcome.isPassed) {
      return outcome;
    }

    if (outcome.isPhaseError) {
      LOG.warn(`${what}: phase error, performing BOT reset recovery`);
      await this.transport.resetRecovery();
      throw new UsbCommunicationException(new Error(`${what} failed with a phase error`));
    }

    const sense = await this.requestSense();
    if (sense.isUnitAttention) {
      LOG.warn(`${what}: unit attention (${sense.toString()}), retrying once`);
      outcome = await this.transport.execute(cb, data, dataIn);
      if (outcome.isPassed) {
        return outcome;
      }
      await this.throwForSense(`${what} failed after unit-attention retry`);
    }

    await this.throwForSense(`${what} failed`, sense);
    return outcome;
  }

  private async requestSense(): Promise<Scsi.SenseData> {
    const buffer = new Uint8Array(REQUEST_SENSE_LENGTH);
    const outcome = await this.transport.execute(Scsi.cdbRequestSense(REQUEST_SENSE_LENGTH), buffer, true);
    if (!outcome.isPassed) {
      return new Scsi.SenseData(0, 0, 0, 0);
    }
    return Scsi.parseSenseData(buffer, 0);
  }

  /**
   * Translates a failed command plus its sense data into the most specific
   * EtchDroid error available, then throws it.
   */
  private async throwForSense(what: string, knownSense?: Scsi.SenseData): Promise<void> {
    const sense = knownSense !== undefined ? knownSense : await this.requestSense();

    if (sense.isMediumNotPresent) {
      throw new MediaNotInsertedException();
    }
    if (sense.isWriteProtected) {
      throw new InitException(`${what}: the drive is write protected`);
    }
    if (sense.hasSenseKey) {
      throw new UsbCommunicationException(new Error(`${what}: sense ${sense.toString()}`));
    }
    throw new UsbCommunicationException(new Error(`${what}: command failed without sense data`));
  }

  async close(): Promise<void> {
    this.initialized = false;
    await this.transport.close();
  }
}
