/*
 * Port of eu.depau.etchdroid.Intents.kt's JobStatusInfo plus the ui.JobState enum.
 *
 * Upstream ships these across process boundaries inside Intents; here they are
 * plain in-process data, so the transport-specific parts (Uri/Uri Parcelable,
 * Parcelable descriptors) are replaced by the picker's own uri string and a
 * serializable DeviceInfo.
 */

import { EtchDroidException } from './exceptions/Exceptions';
import { DeviceInfo } from './massstorage/UsbMassStorageDevice';

/** Which screen the progress flow should show. Mirrors upstream's JobState. */
export enum JobState {
  IN_PROGRESS = 0,
  SUCCESS = 1,
  FATAL_ERROR = 2,
  RECOVERABLE_ERROR = 3,
}

/** One progress/error/finished update for a running job. */
@Observed
export class JobStatus {
  imageUri: string = '';
  /** Display name of the source image; upstream re-queries the Uri for it. */
  imageName: string = '';
  destDevice: DeviceInfo = new DeviceInfo();
  processedBytes: number = 0;
  totalBytes: number = 0;
  speed: number = -1;
  jobId: number = -1;
  isVerifying: boolean = false;
  exception: EtchDroidException | null = null;

  /**
   * Completion percentage, or -1 while the total is still unknown. Upstream
   * computes this on demand rather than storing it, so a stale copy can never
   * disagree with the byte counts.
   */
  get percent(): number {
    if (this.totalBytes <= 0) {
      return -1;
    }
    return Math.floor(this.processedBytes * 100 / this.totalBytes);
  }

  copy(): JobStatus {
    const out = new JobStatus();
    out.imageUri = this.imageUri;
    out.imageName = this.imageName;
    out.destDevice = this.destDevice;
    out.processedBytes = this.processedBytes;
    out.totalBytes = this.totalBytes;
    out.speed = this.speed;
    out.jobId = this.jobId;
    out.isVerifying = this.isVerifying;
    out.exception = this.exception;
    return out;
  }
}
