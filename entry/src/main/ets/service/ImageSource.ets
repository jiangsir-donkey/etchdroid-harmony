/*
 * Seekable reader over the image file the user picked.
 *
 * Upstream opens the image through ContentResolver.openInputStream() and pushes
 * it through a BufferedInputStream; ArkTS hands out a raw file descriptor
 * instead, so this class restores the same seekable-stream shape the write and
 * verify pipelines expect (size / read / seek / skip / close).
 *
 * Reads are asynchronous: a 2 MiB image chunk read synchronously on the UI
 * thread would visibly stall the progress screen.
 */

import { fileIo } from '@kit.CoreFileKit';
import { OpenFileException, toError } from '../exceptions/Exceptions';

/**
 * A file opened for sequential reading with random access.
 *
 * `read()` mirrors InputStream.read(byte[]) exactly: it returns the number of
 * bytes placed at the front of `buffer`, or -1 once the file is exhausted. A
 * short read is normal and callers must use the returned count.
 */
export class ImageSource {
  private fd: number = -1;
  private readonly fileSize: number;
  private position: number = 0;

  private constructor(fd: number, size: number) {
    this.fd = fd;
    this.fileSize = size;
  }

  /** Opens the picker URI. Throws OpenFileException when it cannot be read. */
  static open(uri: string): ImageSource {
    let fd = -1;
    try {
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      fd = file.fd;
      const stat = fileIo.statSync(fd);
      return new ImageSource(fd, stat.size);
    } catch (error) {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (ignored) {
          // best effort while already failing
        }
      }
      throw new OpenFileException('Failed to open image file', toError(error));
    }
  }

  /** Total size in bytes, as reported by the filesystem. */
  get size(): number {
    return this.fileSize;
  }

  /** Current read position. */
  get currentOffset(): number {
    return this.position;
  }

  private get isClosed(): boolean {
    return this.fd < 0;
  }

  /**
   * Reads up to `buffer.length` bytes into `buffer`.
   *
   * The buffer must be a view whose `byteOffset` is 0, because the underlying
   * kernel read always fills from the start of its ArrayBuffer.
   */
  async read(buffer: Uint8Array): Promise<number> {
    if (this.isClosed) {
      throw new OpenFileException('Attempted to read a closed image file');
    }
    const wanted = buffer.length;
    if (wanted === 0) {
      return 0;
    }
    if (this.position >= this.fileSize) {
      return -1;
    }

    try {
      // Offset explicitly instead of relying on the descriptor's file pointer, so
      // a seek never has to race an in-flight read.
      fileIo.lseek(this.fd, this.position, fileIo.WhenceType.SEEK_SET);
      const n = await fileIo.read(this.fd, buffer.buffer as ArrayBuffer);
      if (n <= 0) {
        return -1;
      }
      this.position += n;
      return n;
    } catch (error) {
      throw new OpenFileException('Failed to read image file', toError(error));
    }
  }

  /** Moves the read position to `offset`. */
  seek(offset: number): void {
    this.position = Math.min(Math.max(offset, 0), this.fileSize);
  }

  /** Skips `n` bytes, returning how many were actually skipped. */
  skip(n: number): number {
    const before = this.position;
    this.seek(this.position + n);
    return this.position - before;
  }

  /** Closes the descriptor. Safe to call more than once. */
  close(): void {
    if (this.isClosed) {
      return;
    }
    const fd = this.fd;
    this.fd = -1;
    try {
      fileIo.closeSync(fd);
    } catch (ignored) {
      // Closing in a finally block must never mask the real failure.
    }
  }
}
