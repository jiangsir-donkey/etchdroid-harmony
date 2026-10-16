import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xE7C4;

/** Thin hilog wrapper so the ported mass-storage/service code can log like upstream. */
export class Logger {
  private readonly tag: string;

  constructor(tag: string) {
    this.tag = tag;
  }

  debug(message: string): void {
    hilog.debug(DOMAIN, this.tag, '%{public}s', message);
  }

  info(message: string): void {
    hilog.info(DOMAIN, this.tag, '%{public}s', message);
  }

  warn(message: string): void {
    hilog.warn(DOMAIN, this.tag, '%{public}s', message);
  }

  error(message: string): void {
    hilog.error(DOMAIN, this.tag, '%{public}s', message);
  }
}
