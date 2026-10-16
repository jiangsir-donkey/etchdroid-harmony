/*
 * Buffered, seekable, asynchronous input stream over a block device.
 *
 * ArkTS replacement for eu.depau.etchdroid.massstorage.BlockDeviceInputStream.
 * Upstream runs a background I/O thread that reads blocks ahead of the consumer and
 * submits them to a Channel. Here a single async worker fills an AsyncQueue with the
 * same back-pressure, which gives the read-ahead behaviour verification depends on.
 */

import { Logger } from '../utils/Logger';
import { toError } from '../exceptions/Exceptions';
import { AsyncQueue, QueueClosedError } from '../utils/AsyncQueue';
import { ScsiBlockDevice } from './ScsiBlockDevice';

const LOG = new Logger('BlockDeviceInputStream');

/** A run of blocks read ahead of the consumer. */
class PrefetchedBuffer {
  readonly blockNumber: number;
  readonly data: Uint8Array;

  constructor(blockNumber: number, data: Uint8Array) {
    this.blockNumber = blockNumber;
    this.data = data;
  }
}

export class BlockDeviceInputStream {
  private readonly blockDev: ScsiBlockDevice;
  private readonly blockSize: number;
  private readonly sizeBytes: number;
  private readonly totalBlocks: number;
  private readonly bufferBlocks: number;
  private readonly prefetchBuffers: number;

  /** Current read buffer and where it starts. */
  private buffer: Uint8Array | null = null;
  private bufferStartBlock: number = 0;
  private bufferPosition: number = 0;

  /** Prefetch queue and worker state. */
  private queue: AsyncQueue<PrefetchedBuffer> | null = null;
  private workerRunning: boolean = false;
  private workerPromise: Promise<void> | null = null;
  private readNextBlockNumber: number = 0;
  private inFlightBlockNumber: number = -1;

  private markedPosition: number = -1;

  constructor(blockDev: ScsiBlockDevice, bufferBlocks: number = 512, prefetchBuffers: number = 4) {
    this.blockDev = blockDev;
    this.blockSize = blockDev.blockSize;
    this.sizeBytes = blockDev.sizeInBytes;
    this.totalBlocks = blockDev.blocks;
    this.bufferBlocks = bufferBlocks;
    this.prefetchBuffers = Math.max(1, prefetchBuffers);
  }

  /** Byte offset from the start of the block device. */
  get currentOffset(): number {
    return this.bufferStartBlock * this.blockSize + this.bufferPosition;
  }

  private get bufferRemaining(): number {
    return this.buffer === null ? 0 : this.buffer.length - this.bufferPosition;
  }

  private get isEof(): boolean {
    return this.currentOffset >= this.sizeBytes;
  }

  // -------------------------------------------------------------------------
  // Reading
  // -------------------------------------------------------------------------

  /** Reads a single byte, or -1 at end of device. */
  async readByteAsync(): Promise<number> {
    if (this.isEof) {
      return -1;
    }
    await this.ensureBuffer();
    const buffer = this.buffer as Uint8Array;
    const value = buffer[this.bufferPosition] & 0xFF;
    this.bufferPosition++;
    if (this.bufferRemaining === 0) {
      await this.loadNextBuffer();
    }
    return value;
  }

  /**
   * Reads up to `len` bytes into `target` at `off`.
   *
   * @returns the number of bytes read, or -1 when already at end of device
   */
  async readAsync(target: Uint8Array, off: number, len: number): Promise<number> {
    if (len === 0) {
      return 0;
    }
    if (this.isEof) {
      return -1;
    }

    await this.ensureBuffer();

    const bytesToRead = Math.min(len, this.sizeBytes - this.currentOffset, target.length - off);
    let bytesRead = 0;

    while (bytesRead < bytesToRead) {
      if (this.isEof) {
        break;
      }
      const remaining = bytesToRead - bytesRead;
      const toCopy = Math.min(remaining, this.bufferRemaining);

      if (toCopy <= 0) {
        await this.loadNextBuffer();
        continue;
      }

      const buffer = this.buffer as Uint8Array;
      target.set(buffer.subarray(this.bufferPosition, this.bufferPosition + toCopy), off + bytesRead);
      this.bufferPosition += toCopy;
      bytesRead += toCopy;

      if (bytesRead < bytesToRead) {
        await this.loadNextBuffer();
      }
    }
    return bytesRead;
  }

  /** Reads up to `target.length` bytes into `target`. */
  async readAsyncAll(target: Uint8Array): Promise<number> {
    return await this.readAsync(target, 0, target.length);
  }

  /** Bytes buffered and available without waiting on the device. */
  available(): number {
    return this.bufferRemaining;
  }

  // -------------------------------------------------------------------------
  // Positioning
  // -------------------------------------------------------------------------

  /**
   * Seeks by `offset` bytes.
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

    const position = this.currentOffset + actualSkipDistance;
    await this.setPosition(position);
    return actualSkipDistance;
  }

  /** Alias of seekAsync(), matching upstream's AsyncInputStream contract. */
  async skipAsync(n: number): Promise<number> {
    return await this.seekAsync(n);
  }

  /** Marks the current position. Only one mark is kept. */
  mark(): void {
    this.markedPosition = this.currentOffset;
  }

  /** Returns to the marked position. */
  async resetAsync(): Promise<void> {
    if (this.markedPosition < 0) {
      throw new Error('Stream not marked');
    }
    await this.setPosition(this.markedPosition);
  }

  private async setPosition(position: number): Promise<void> {
    if (position < 0) {
      throw new Error(`Position must be >= 0, got ${position}`);
    }
    const newPosition = Math.min(position, this.sizeBytes);

    if (newPosition === this.sizeBytes) {
      this.bufferStartBlock = this.totalBlocks;
      this.bufferPosition = 0;
      this.buffer = new Uint8Array(0);
      return;
    }

    const newBlockOffset = Math.floor(newPosition / this.blockSize);
    const newByteOffset = newPosition % this.blockSize;

    // Fast path: still inside the buffer we already hold.
    if (this.buffer !== null &&
      newBlockOffset >= this.bufferStartBlock &&
      newBlockOffset < this.bufferStartBlock + this.bufferBlocks) {
      this.bufferPosition = (newBlockOffset - this.bufferStartBlock) * this.blockSize + newByteOffset;
      return;
    }

    let result = this.tryGetBufferNonBlocking(newBlockOffset);
    if (result === null) {
      if (!this.isInFlight(newBlockOffset)) {
        this.readNextBlockNumber = newBlockOffset;
      }
      await this.ensureIoThread();
      result = await this.waitAndGetBuffer(newBlockOffset);
    }

    this.buffer = result.data;
    this.bufferStartBlock = result.blockNumber;
    this.bufferPosition = (newBlockOffset - result.blockNumber) * this.blockSize + newByteOffset;
  }

  private async ensureBuffer(): Promise<void> {
    if (this.buffer === null) {
      await this.setPosition(this.currentOffset);
    }
    if (!this.isEof && this.bufferRemaining === 0) {
      await this.loadNextBuffer();
    }
  }

  private async loadNextBuffer(): Promise<void> {
    await this.setPosition((this.bufferStartBlock + this.bufferBlocks) * this.blockSize);
  }

  // -------------------------------------------------------------------------
  // Prefetch worker
  // -------------------------------------------------------------------------

  private isInFlight(blockNumber: number): boolean {
    if (this.inFlightBlockNumber < 0) {
      return false;
    }
    return blockNumber >= this.inFlightBlockNumber &&
      blockNumber < this.inFlightBlockNumber + this.bufferBlocks;
  }

  private async waitAndGetBuffer(wantedBlockNumber: number): Promise<PrefetchedBuffer> {
    const queue = this.queue;
    if (queue === null) {
      throw new Error('Prefetch queue is not initialized');
    }
    for (;;) {
      const entry = await queue.receive();
      if (wantedBlockNumber >= entry.blockNumber &&
        wantedBlockNumber < entry.blockNumber + this.bufferBlocks) {
        return entry;
      }
    }
  }

  private tryGetBufferNonBlocking(wantedBlockNumber: number): PrefetchedBuffer | null {
    const queue = this.queue;
    if (queue === null) {
      return null;
    }
    for (;;) {
      const entry = queue.tryReceive();
      if (entry === null) {
        return null;
      }
      if (wantedBlockNumber >= entry.blockNumber &&
        wantedBlockNumber < entry.blockNumber + this.bufferBlocks) {
        return entry;
      }
    }
  }

  /** Starts the prefetch worker if it is not already running. */
  private async ensureIoThread(): Promise<void> {
    if (this.workerRunning) {
      return;
    }

    if (this.queue === null) {
      this.queue = new AsyncQueue<PrefetchedBuffer>(this.prefetchBuffers);
    } else {
      // Abandon stale prefetches from the previous run, matching upstream's
      // channel replacement, and honour any error that ended it.
      const previous = this.queue;
      this.queue = new AsyncQueue<PrefetchedBuffer>(this.prefetchBuffers);
      previous.close();
    }

    const queue = this.queue;
    this.workerRunning = true;
    this.workerPromise = this.runWorker(queue);
  }

  private async runWorker(queue: AsyncQueue<PrefetchedBuffer>): Promise<void> {
    try {
      for (;;) {
        const blockNumber = this.readNextBlockNumber;
        this.readNextBlockNumber += this.bufferBlocks;
        if (blockNumber < 0 || blockNumber >= this.totalBlocks) {
          break;
        }
        this.inFlightBlockNumber = blockNumber;

        const bytes = Math.min(this.sizeBytes - blockNumber * this.blockSize, this.blockSize * this.bufferBlocks);
        const data = new Uint8Array(bytes);
        await this.blockDev.read(blockNumber, data);

        if (!await queue.send(new PrefetchedBuffer(blockNumber, data))) {
          break;
        }
      }
    } catch (error) {
      queue.close(toError(error as Object));
      LOG.error(`Prefetch worker stopped: ${toError(error as Object).message}`);
    }
    this.inFlightBlockNumber = -1;
    this.workerRunning = false;
  }

  // -------------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------------

  /** Stops the prefetch worker and releases buffered data. */
  async closeAsync(): Promise<void> {
    const queue = this.queue;
    if (queue === null) {
      return;
    }

    await this.setPosition(this.sizeBytes);
    queue.close();

    // Unblock a worker parked on a full queue, then discard anything in flight.
    for (;;) {
      try {
        await queue.receive();
      } catch (error) {
        if (error instanceof QueueClosedError) {
          break;
        }
        break;
      }
    }
    queue.drain();

    const worker = this.workerPromise;
    if (worker !== null) {
      await worker;
    }
  }
}
