/**
 * A bounded asynchronous FIFO, standing in for the Kotlin coroutine Channels the
 * upstream streams use to hand blocks between their producer and I/O workers.
 *
 * ArkTS runs on a single-threaded event loop rather than OS threads, but the same
 * producer/consumer contract is needed: send() blocks once the queue is full,
 * receive() blocks until an item arrives, and closing wakes everyone up so a
 * stuck worker can always terminate.
 */

/** Raised by receive() once a closed queue has been fully drained. */
export class QueueClosedError extends Error {
  constructor(message: string = 'Queue is closed') {
    super(message);
    this.name = 'QueueClosedError';
  }
}

export class AsyncQueue<T> {
  private readonly items: T[] = [];
  private readonly capacity: number;
  private isClosed: boolean = false;
  private closeError: Error | null = null;
  private readonly sendWaiters: (() => void)[] = [];
  private readonly receiveWaiters: (() => void)[] = [];

  constructor(capacity: number) {
    this.capacity = Math.max(1, capacity);
  }

  get isFull(): boolean {
    return this.items.length >= this.capacity;
  }

  get isEmpty(): boolean {
    return this.items.length === 0;
  }

  get length(): number {
    return this.items.length;
  }

  get closed(): boolean {
    return this.isClosed;
  }

  /**
   * Appends an item, waiting for space when the queue is full.
   *
   * @returns false when the queue was closed instead of accepting the item
   */
  async send(item: T): Promise<boolean> {
    while (this.items.length >= this.capacity) {
      if (this.isClosed) {
        return false;
      }
      await this.waitForSpace();
    }
    if (this.isClosed) {
      return false;
    }
    this.items.push(item);
    this.wakeReceivers();
    return true;
  }

  /**
   * Removes and returns the oldest item, waiting when the queue is empty.
   *
   * @throws QueueClosedError (or the recorded close error) once drained and closed
   */
  async receive(): Promise<T> {
    while (this.items.length === 0) {
      if (this.isClosed) {
        throw this.closeError !== null ? this.closeError : new QueueClosedError();
      }
      await this.waitForItem();
    }
    const item = this.items.shift();
    this.wakeSenders();
    return item as T;
  }

  /** Removes and returns the oldest item, or null when there is nothing buffered. */
  tryReceive(): T | null {
    if (this.items.length === 0) {
      return null;
    }
    const item = this.items.shift();
    this.wakeSenders();
    return item as T;
  }

  /** Discards every buffered item, waking any blocked senders. */
  drain(): void {
    this.items.length = 0;
    this.wakeSenders();
  }

  /**
   * Closes the queue. Buffered items can still be received; once the queue is
   * empty, receive() throws.
   */
  close(error?: Error): void {
    if (this.isClosed) {
      return;
    }
    this.isClosed = true;
    this.closeError = error !== undefined ? error : null;
    this.wakeSenders();
    this.wakeReceivers();
  }

  private waitForSpace(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      this.sendWaiters.push(resolve);
    });
  }

  private waitForItem(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      this.receiveWaiters.push(resolve);
    });
  }

  private wakeSenders(): void {
    const waiters = this.sendWaiters.splice(0, this.sendWaiters.length);
    for (const waiter of waiters) {
      waiter();
    }
  }

  private wakeReceivers(): void {
    const waiters = this.receiveWaiters.splice(0, this.receiveWaiters.length);
    for (const waiter of waiters) {
      waiter();
    }
  }
}
