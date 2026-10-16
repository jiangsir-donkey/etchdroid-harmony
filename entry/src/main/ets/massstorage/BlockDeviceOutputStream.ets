/*
 * Buffered, seekable, asynchronous output stream over a block device.
 *
 * ArkTS replacement for eu.depau.etchdroid.massstorage.BlockDeviceOutputStream.
 * The original overlaps source-file reads with USB writes by queueing committed
 * buffers to a background I/O worker. ArkTS has no threads, so the same overlap is
 * achieved with a promise chain: commit() hands a buffer to runWrite() without
 * awaiting it and only blocks once MAX_IN_FLIGHT writes are outstanding, which is
 * exactly the back-pressure the upstream Channel(queueSize) provides.
 */

import { Logger } from '../utils/Logger';
import { toError } from '../exceptions/Exceptions';
import { ScsiBlockDevice } from './ScsiBlockDevice';

const LOG = new Logger('BlockDeviceOutputStream');

/** One buffer handed to the write pipeline. */
class PendingWrite {
  readonly blockNumber: number;
  readonly data: Uint8Array;
  readonly length: number;

  constructor(blockNumber: number, data: Uint8Array, length: number) {
    this.blockNumber = blockNumber;
    this.data = data;
    this.length = length;
  }
}

export class BlockDeviceOutputStream {
  private readonly blockDev: ScsiBlockDevice;
  private readonly blockSize: number;
  private readonly sizeBytes: number;
  private readonly bufferBlocks: number;
  private readonly maxInFlight: number;

  /** Block index the current buffer starts at. */
  private bufferStartBlock: number = 0;
  /** Buffer holding data not yet committed, plus how much of it is valid. */
  private bufferData: Uint8Array;
  private bufferLength: number = 0;

  private closed: boolean = false;

  /** Serializes writes: USB Bulk-Only Transport allows only one command at a time. */
  private tail: Promise<void> = Promise.resolve();
  private pending: number = 0;
  private failure: Error | null = null;
  private readonly progressWaiters: (() => void)[] = [];

  constructor(blockDev: ScsiBlockDevice, bufferBlocks: number = 512, queueSize: number = 4) {
    this.blockDev = blockDev;
    this.blockSize = blockDev.blockSize;
    this.sizeBytes = blockDev.sizeInBytes;
    this.bufferBlocks = bufferBlocks;
    this.maxInFlight = Math.max(1, queueSize);
    this.bufferData = new Uint8Array(this.capacityAt(0));
  }

  /** Byte offset from the start of the block device. */
  get currentOffset(): number {
    return this.bufferStartBlock * this.blockSize + this.bufferLength;
  }

  private get isEof(): boolean {
    return this.currentOffset >= this.sizeBytes;
  }

  /** Buffer capacity when positioned at `byteOffset`, never negative. */
  private capacityAt(byteOffset: number): number {
    return Math.max(0, Math.min(this.blockSize * this.bufferBlocks, this.sizeBytes - byteOffset));
  }

  // -------------------------------------------------------------------------
  // Writing
  // -------------------------------------------------------------------------

  /** Writes a single byte. */
  async writeByteAsync(value: number): Promise<void> {
    if (this.isEof) {
      throw new Error('No space left on device');
    }
    if (this.bufferLength === this.bufferData.length) {
      await this.commit();
    }
    this.bufferData[this.bufferLength] = value & 0xFF;
    this.bufferLength++;
    if (this.bufferLength === this.bufferData.length) {
      await this.commit();
    }
  }

  /** Writes `len` bytes from `data` starting at `off`. */
  async writeAsync(data: Uint8Array, off: number, len: number): Promise<void> {
    if (len <= 0 || off > data.length) {
      return;
    }
    if (this.isEof) {
      throw new Error('No space left on device');
    }

    const actualLen = Math.min(len, data.length - off);
    let toWrite = actualLen;

    while (toWrite > 0) {
      if (this.isEof) {
        throw new Error('No space left on device');
      }
      const space = this.bufferData.length - this.bufferLength;
      if (space === 0) {
        await this.commit();
        continue;
      }

      const toWriteNow = Math.min(toWrite, space);
      const sourceStart = off + actualLen - toWrite;
      this.bufferData.set(data.subarray(sourceStart, sourceStart + toWriteNow), this.bufferLength);
      this.bufferLength += toWriteNow;
      toWrite -= toWriteNow;

      if (toWrite > 0 && this.bufferLength === this.bufferData.length) {
        await this.commit();
      }
    }

    if (this.bufferLength === this.bufferData.length) {
      await this.commit();
    }
  }

  /** Writes the whole array. */
  async writeAsyncAll(data: Uint8Array): Promise<void> {
    await this.writeAsync(data, 0, data.length);
  }

  // -------------------------------------------------------------------------
  // Commit pipeline
  // -------------------------------------------------------------------------

  /**
   * Hands the current buffer to the write pipeline and starts a fresh one.
   *
   * When the buffer ends mid-block, that trailing partial block is copied into the
   * new buffer and the old one is completed by a read-modify-write in the worker,
   * so the bytes beyond the written range keep their previous on-device content.
   */
  private async commit(): Promise<void> {
    if (this.bufferLength === 0) {
      return;
    }

    const committedLength = this.bufferLength;
    const newOffset = this.bufferStartBlock * this.blockSize + committedLength;
    const newData = new Uint8Array(this.capacityAt(newOffset));

    let newLength = 0;
    const remainder = committedLength % this.blockSize;
    if (remainder !== 0) {
      const partialStart = committedLength - remainder;
      newData.set(this.bufferData.subarray(partialStart, committedLength), 0);
      newLength = remainder;
    }

    this.enqueue(new PendingWrite(this.bufferStartBlock, this.bufferData, committedLength));
    this.bufferData = newData;
    this.bufferLength = newLength;
    this.bufferStartBlock += Math.floor(committedLength / this.blockSize);

    // Back-pressure: let at most maxInFlight writes be outstanding.
    while (this.pending >= this.maxInFlight) {
      if (this.failure !== null) {
        throw this.failure;
      }
      await this.waitForProgress();
    }
    if (this.failure !== null) {
      throw this.failure;
    }
  }

  private enqueue(request: PendingWrite): void {
    this.pending++;
    this.tail = this.tail.then(async (): Promise<void> => {
      try {
        await this.runWrite(request);
      } catch (error) {
        if (this.failure === null) {
          this.failure = toError(error as Object);
        }
      } finally {
        this.pending--;
        this.wakeProgressWaiters();
      }
    });
  }

  /** Writes one committed buffer, completing a trailing partial block first. */
  private async runWrite(request: PendingWrite): Promise<void> {
    let data = request.data;
    let length = request.length;

    if (length % this.blockSize !== 0) {
      const lastBlockOffset = length - (length % this.blockSize);
      const blankOffset = length % this.blockSize;
      const lastBlockNumber = request.blockNumber + Math.floor(length / this.blockSize);

      if (data.length < lastBlockOffset + this.blockSize) {
        const expanded = new Uint8Array(lastBlockOffset + this.blockSize);
        expanded.set(data.subarray(0, length), 0);
        data = expanded;
      }

      const existing = new Uint8Array(this.blockSize);
      await this.blockDev.read(lastBlockNumber, existing);
      for (let i = blankOffset; i < this.blockSize; i++) {
        data[lastBlockOffset + i] = existing[i];
      }
      length = lastBlockOffset + this.blockSize;
    }

    if (length === 0) {
      return;
    }
    await this.blockDev.write(request.blockNumber, data.subarray(0, length));
  }

  private waitForProgress(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      this.progressWaiters.push(resolve);
    });
  }

  private wakeProgressWaiters(): void {
    const waiters = this.progressWaiters.splice(0, this.progressWaiters.length);
    for (const waiter of waiters) {
      waiter();
    }
  }

  // -------------------------------------------------------------------------
  // Flush / seek / close
  // -------------------------------------------------------------------------

  /**
   * Commits any buffered data and waits until every queued write has reached the
   * device. Blocks until the write queue is empty.
   */
  async flushAsync(): Promise<void> {
    await this.commit();
    while (this.pending > 0) {
      if (this.failure !== null) {
        throw this.failure;
      }
      await this.waitForProgress();
    }
    if (this.failure !== null) {
      throw this.failure;
    }
  }

  /**
   * Seeks by `offset` bytes. May flush the buffer and block until the queue is
   * empty, so expect delays when seeking.
   *
   * @returns the distance actually skipped
   */
  async seekAsync(offset: number): Promise<number> {
    if (offset === 0) {
      return 0;
    }

    let actualSkipDistance = offset;
    if (this.currentOffset + offset > this.sizeBytes) {
      actualSkipDistance = this.sizeBytes - this.currentOffset;
    } else if (this.currentOffset + offset < 0) {
      actualSkipDistance = -this.currentOffset;
    }

    const newByteOffset = this.currentOffset + actualSkipDistance;
    const newBlockOffset = Math.floor(newByteOffset / this.blockSize);
    const byteWithinBlock = newByteOffset % this.blockSize;

    // Fast path: the destination is inside the range the current buffer covers.
    const writtenBlocks = Math.floor(this.bufferLength / this.blockSize);
    if (newBlockOffset >= this.bufferStartBlock &&
      newBlockOffset < this.bufferStartBlock + writtenBlocks) {
      this.bufferLength =
        (newBlockOffset - this.bufferStartBlock) * this.blockSize + byteWithinBlock;
      return actualSkipDistance;
    }

    await this.flushAsync();

    this.bufferStartBlock = newBlockOffset;
    this.bufferData = new Uint8Array(this.capacityAt(newBlockOffset * this.blockSize));
    this.bufferLength = 0;

    if (byteWithinBlock !== 0) {
      // Keep the untouched prefix of the destination block so a later partial
      // write does not clobber it.
      const existing = new Uint8Array(this.blockSize);
      await this.blockDev.read(newBlockOffset, existing);
      this.bufferData.set(existing.subarray(0, byteWithinBlock), 0);
      this.bufferLength = byteWithinBlock;
    }

    LOG.debug(`Seeked by ${actualSkipDistance} bytes to offset ${this.currentOffset}`);
    return actualSkipDistance;
  }

  /** Flushes and shuts the stream down. Any write failure surfaces here. */
  async closeAsync(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    await this.flushAsync();
  }
}
