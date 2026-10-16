/*
 * Port of eu.depau.etchdroid.utils.timeoutWatchdog.
 *
 * Upstream races a coroutine against a deadline that a bump() call keeps pushing
 * forward, so a transfer that keeps making progress is never interrupted while a
 * genuinely wedged one is. This is the promise-based equivalent.
 *
 * Note: unlike coroutine cancellation, a promise cannot be cancelled, so the work
 * is left running when the deadline fires. That is safe here because every USB
 * transfer carries its own finite timeout in BulkOnlyTransport.
 */

/** Thrown when the deadline elapses without a bump(). */
export class TimeoutExpiredException extends Error {
  constructor() {
    super('Timeout expired');
    this.name = 'TimeoutExpiredException';
  }
}

/** Receives progress notifications that postpone the deadline. */
export class TimeoutBump {
  private readonly timeoutMillis: number;
  private expirationTime: number;

  constructor(timeoutMillis: number) {
    this.timeoutMillis = timeoutMillis;
    this.expirationTime = Date.now() + timeoutMillis;
  }

  bump(): void {
    this.expirationTime = Date.now() + this.timeoutMillis;
  }

  get remaining(): number {
    return this.expirationTime - Date.now();
  }

  get isExpired(): boolean {
    return this.remaining <= 0;
  }
}

function delay(millis: number): Promise<boolean> {
  return new Promise<boolean>((resolve: (value: boolean) => void) => {
    setTimeout(() => resolve(false), Math.max(0, millis));
  });
}

/**
 * Runs `block`, aborting with TimeoutExpiredException when it stops calling
 * bump() for `timeMillis`.
 */
export async function timeoutWatchdog<T>(
  timeMillis: number,
  block: (bump: TimeoutBump) => Promise<T>,
): Promise<T> {
  const bump = new TimeoutBump(timeMillis);
  const work = block(bump);

  // Settle the work either way so a later failure cannot surface as an unhandled
  // rejection after the watchdog has already thrown.
  const settled: Promise<boolean> = work.then(
    (): boolean => true,
    (): boolean => true,
  );

  for (;;) {
    if (bump.isExpired) {
      throw new TimeoutExpiredException();
    }
    const outcome: boolean = await Promise.race([settled, delay(bump.remaining)]);
    if (outcome) {
      return await work;
    }
  }
}
