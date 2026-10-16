/*
 * Port of eu.depau.etchdroid.service.WorkerService (and its
 * WorkerServiceFlowImpl helper object).
 *
 * Android runs this on a LifecycleService with a background coroutine; ArkTS is
 * single-threaded and every USB and file operation is already asynchronous, so
 * the job is a plain async method. The queueing that upstream gets from
 * coroutines and the BlockDeviceStream classes is unchanged: the input side is
 * prefetched through an AsyncQueue and the output side keeps at most
 * QUEUE_SIZE writes in flight, so neither ever lets the USB pipe go idle.
 */

import { Logger } from '../utils/Logger';
import { toHrSize } from '../utils/Format';
import { timeoutWatchdog, TimeoutBump, TimeoutExpiredException } from '../utils/Watchdog';
import {
  EtchDroidException,
  InitException,
  MissingDeviceException,
  NotEnoughSpaceException,
  UsbCommunicationException,
  UsbDriveTooLargeException,
  VerificationFailedException,
  toError,
  toEtchDroidException,
} from '../exceptions/Exceptions';
import {
  DeviceInfo,
  findMassStorageDevice,
  UsbMassStorageDevice,
} from '../massstorage/UsbMassStorageDevice';
import { ScsiBlockDevice } from '../massstorage/ScsiBlockDevice';
import { BlockDeviceInputStream } from '../massstorage/BlockDeviceInputStream';
import { BlockDeviceOutputStream } from '../massstorage/BlockDeviceOutputStream';
import { ImageSource } from './ImageSource';

const LOG = new Logger('WorkerService');

/** Upstream's tuning constants, kept identical so throughput characteristics match. */
export const BUFFER_BLOCKS = 4096;
export const QUEUE_SIZE = 2;
export const IO_TIMEOUT = 10 * 1000;

/** Verification compares this many bytes at a time, as upstream does. */
const VERIFY_CHUNK = 1024;

/** One write/verify request. Mirrors the extras upstream packs into START_JOB. */
export class JobRequest {
  imageUri: string = '';
  device: DeviceInfo = new DeviceInfo();
  jobId: number = -1;
  offset: number = 0;
  verifyOnly: boolean = false;
}

/** Where the job reports progress, and asks whether verification was skipped. */
export interface JobSink {
  onProgress(processedBytes: number, totalBytes: number, speed: number, isVerifying: boolean): void;
  isVerificationCancelled(): boolean;
}

/**
 * Upstream's sendProgressUpdate: at most one update per second, with the
 * reported speed averaged over the last ten samples weighted 1..N so a single
 * stalled second cannot dominate the displayed rate.
 */
class ProgressReporter {
  private static readonly UPDATE_INTERVAL = 1000;
  private static readonly MAX_SAMPLES = 10;

  private readonly sink: JobSink;
  private lastUpdate: number = -1;
  private bytesSinceLastUpdate: number = 0;
  private readonly speeds: number[] = [];

  constructor(sink: JobSink) {
    this.sink = sink;
  }

  /** Discards history, so verification is not measured against write samples. */
  reset(): void {
    this.lastUpdate = -1;
    this.bytesSinceLastUpdate = 0;
    this.speeds.length = 0;
  }

  report(lastWrittenBytes: number, processedBytes: number, imageSize: number, isVerifying: boolean): void {
    this.bytesSinceLastUpdate += lastWrittenBytes;
    const now = Date.now();

    if (this.lastUpdate + ProgressReporter.UPDATE_INTERVAL > now) {
      return;
    }

    const interval = now - this.lastUpdate;
    const effectiveInterval = interval > 0 ? interval : ProgressReporter.UPDATE_INTERVAL;
    const speed = this.bytesSinceLastUpdate / effectiveInterval * 1000;
    this.speeds.push(speed);
    if (this.speeds.length > ProgressReporter.MAX_SAMPLES) {
      this.speeds.shift();
    }

    let weighted = 0;
    let weightTotal = 0;
    for (let i = 0; i < this.speeds.length; i++) {
      const weight = i + 1;
      weighted += this.speeds[i] * weight;
      weightTotal += weight;
    }
    const averaged = weightTotal > 0 ? weighted / weightTotal : speed;

    this.lastUpdate = now;
    this.bytesSinceLastUpdate = 0;
    this.sink.onProgress(processedBytes, imageSize, averaged, isVerifying);
  }
}

/**
 * Runs one write-then-verify job.
 *
 * Upstream writes the image and then re-reads the whole device to compare it
 * against the source, and only reports success once both stages finish.
 */
export class WorkerService {
  private readonly request: JobRequest;
  private readonly sink: JobSink;
  private readonly reporter: ProgressReporter;

  constructor(request: JobRequest, sink: JobSink) {
    this.request = request;
    this.sink = sink;
    this.reporter = new ProgressReporter(sink);
  }

  /**
   * Executes the job.
   *
   * @throws EtchDroidException classified exactly as upstream does, so the UI can
   *         decide between the fatal and the recoverable error screen.
   */
  async run(): Promise<void> {
    const request = this.request;
    let device: UsbMassStorageDevice | null = null;
    let source: ImageSource | null = null;
    let currentOffset = request.offset;
    let imageSize = 0;

    try {
      const descriptor = findMassStorageDevice(request.device);
      if (descriptor === null) {
        throw new MissingDeviceException();
      }

      source = ImageSource.open(request.imageUri);
      imageSize = source.size;

      LOG.info(`Building USB mass storage device for ${descriptor.name}`);
      device = new UsbMassStorageDevice(descriptor);
      try {
        await device.open();
      } catch (error) {
        if (error instanceof EtchDroidException) {
          throw error;
        }
        throw new InitException('Initialization failed', toError(error));
      }

      const blockDev = device.primaryBlockDevice;
      currentOffset = request.offset - (request.offset % blockDev.blockSize);

      // Re-write a few blocks before the resume point: whatever made the previous
      // attempt fail may have left the trailing blocks inconsistent.
      currentOffset = Math.max(currentOffset - blockDev.blockSize * BUFFER_BLOCKS * 2, 0);

      const deviceSize = blockDev.blocks * blockDev.blockSize;
      LOG.info(`Device size: ${toHrSize(deviceSize, false)} (block size: ${blockDev.blockSize}, blocks: ${blockDev.blocks})`);

      if (blockDev.blocks < 0) {
        throw new UsbDriveTooLargeException();
      }

      if (deviceSize < imageSize) {
        throw new NotEnoughSpaceException(imageSize, deviceSize, toHrSize(imageSize), toHrSize(deviceSize));
      }

      const bufferSize = BUFFER_BLOCKS * blockDev.blockSize;

      // Announce the starting offset before any bytes move, mirroring upstream.
      this.sink.onProgress(currentOffset, imageSize, 0, request.verifyOnly);

      if (!request.verifyOnly) {
        LOG.info('Writing image to USB drive');
        await this.writeImage(source, blockDev, imageSize, bufferSize, currentOffset);
      } else {
        LOG.info('Skipping write, only verifying image on USB drive');
      }

      // Always verify the whole image, not just the part that was written.
      source.seek(0);
      this.reporter.reset();
      LOG.info('Verifying image on USB drive');
      await this.verifyImage(source, blockDev, imageSize, bufferSize);

      this.sink.onProgress(imageSize, imageSize, 0, true);
    } catch (error) {
      if (error instanceof EtchDroidException) {
        throw error;
      }
      if (error instanceof TimeoutExpiredException) {
        throw new UsbCommunicationException(toError(error));
      }
      throw toEtchDroidException(error);
    } finally {
      if (source !== null) {
        source.close();
      }
      if (device !== null) {
        await this.closeDevice(device);
      }
    }
  }

  /**
   * Releases the USB device with a bound on how long teardown may take.
   *
   * Upstream does this because a device stuck inside a native libusb transfer can
   * make close() hang forever and wedge the service. Every ArkTS transfer carries
   * its own finite timeout, but a bounded wait keeps a wedged driver from blocking
   * the error screen, so the guard is kept.
   */
  private async closeDevice(device: UsbMassStorageDevice): Promise<void> {
    const closed = device.close();
    const racing = new Promise<boolean>((resolve: (timedOut: boolean) => void) => {
      setTimeout(() => resolve(true), 3000);
    });
    const timedOut = await Promise.race([closed.then((): boolean => false), racing]);
    if (timedOut) {
      LOG.warn('Timed out closing USB drive (device may be stuck in a native transfer)');
    }
  }

  // -------------------------------------------------------------------------
  // Write
  // -------------------------------------------------------------------------

  private async writeImage(
    source: ImageSource,
    blockDev: ScsiBlockDevice,
    imageSize: number,
    bufferSize: number,
    initialOffset: number,
  ): Promise<void> {
    const buffer = new Uint8Array(bufferSize);
    let currentOffset = initialOffset;

    const dst = new BlockDeviceOutputStream(blockDev, BUFFER_BLOCKS / QUEUE_SIZE, QUEUE_SIZE);
    try {
      await timeoutWatchdog(IO_TIMEOUT, async (watchdog: TimeoutBump): Promise<void> => {
        source.seek(currentOffset);
        await dst.seekAsync(currentOffset);

        while (currentOffset < imageSize) {
          watchdog.bump();

          const read = await source.read(buffer);
          if (read === -1) {
            break;
          }

          watchdog.bump();
          try {
            await dst.writeAsync(buffer, 0, read);
            watchdog.bump();
          } catch (error) {
            throw new UsbCommunicationException(toError(error));
          }

          currentOffset += read;
          this.reporter.report(read, currentOffset, imageSize, false);
        }

        watchdog.bump();
        try {
          await dst.flushAsync();
          watchdog.bump();
        } catch (error) {
          throw new UsbCommunicationException(toError(error));
        }
      });
    } finally {
      await dst.closeAsync();
    }
  }

  // -------------------------------------------------------------------------
  // Verify
  // -------------------------------------------------------------------------

  private async verifyImage(
    source: ImageSource,
    blockDev: ScsiBlockDevice,
    imageSize: number,
    bufferSize: number,
  ): Promise<void> {
    const fileBuffer = new Uint8Array(VERIFY_CHUNK);
    const deviceBuffer = new Uint8Array(VERIFY_CHUNK);
    let currentOffset = 0;

    const dst = new BlockDeviceInputStream(blockDev, BUFFER_BLOCKS / QUEUE_SIZE, QUEUE_SIZE);
    try {
      await timeoutWatchdog(IO_TIMEOUT, async (watchdog: TimeoutBump): Promise<void> => {
        await dst.skipAsync(0);
        source.seek(0);
        watchdog.bump();

        while (!this.sink.isVerificationCancelled()) {
          watchdog.bump();

          const read = await source.read(fileBuffer);
          if (read === -1) {
            break;
          }

          watchdog.bump();
          let deviceRead = 0;
          try {
            deviceRead = await dst.readAsync(deviceBuffer, 0, read);
            if (deviceRead < read) {
              throw new Error(`Device read ${deviceRead} < file read ${read}`);
            }
            watchdog.bump();
          } catch (error) {
            throw new UsbCommunicationException(toError(error));
          }

          if (!equalsPrefix(fileBuffer, deviceBuffer, read)) {
            LOG.error('Verification failed: device content does not match the image');
            throw new VerificationFailedException();
          }

          currentOffset += read;
          this.reporter.report(read, currentOffset, imageSize, true);
        }
      });
    } finally {
      try {
        await dst.closeAsync();
      } catch (error) {
        throw new UsbCommunicationException(toError(error));
      }
    }
  }
}

/** Byte-for-byte comparison of the first `length` bytes of two buffers. */
function equalsPrefix(a: Uint8Array, b: Uint8Array, length: number): boolean {
  for (let i = 0; i < length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}
