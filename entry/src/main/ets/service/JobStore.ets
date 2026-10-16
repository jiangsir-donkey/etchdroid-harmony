/*
 * The job state machine that upstream splits between WorkerService, its
 * LocalBroadcastManager intents and ProgressActivityViewModel.
 *
 * Android fans events out through broadcasts because the service and the UI live
 * in different components; here everything is in one process, so the store holds
 * the current JobStatus and notifies registered pages. Because it also keeps the
 * latest status, a page that appears mid-job (for example after the user returns
 * from the launcher) renders the real progress instead of waiting for the next
 * update, which upstream's fire-and-forget broadcasts cannot do.
 */

import { common } from '@kit.AbilityKit';
import { JobState, JobStatus } from '../JobStatus';
import { DeviceInfo } from '../massstorage/UsbMassStorageDevice';
import { JobRequest, JobSink, WorkerService } from './WorkerService';
import { JOB_PROGRESS_NOTIFICATION_ID, NotificationController } from './Notifications';
import {
  EtchDroidException,
  RecoverableException,
  toEtchDroidException,
} from '../exceptions/Exceptions';
import { stringByName } from '../utils/Resources';
import { toHrSize } from '../utils/Format';
import { Logger } from '../utils/Logger';

const LOG = new Logger('JobStore');

/** Receives every state transition of the current job. */
export type JobStateListener = (state: JobState, status: JobStatus) => void;

/** The image and drive chosen on the main screen, awaiting confirmation. */
export class PendingSelection {
  imageUri: string = '';
  fileName: string = '';
  device: DeviceInfo = new DeviceInfo();
}

export class JobStore implements JobSink {
  private static instance: JobStore | null = null;

  private state: JobState = JobState.IN_PROGRESS;
  private status: JobStatus = new JobStatus();
  private readonly listeners: JobStateListener[] = [];

  /** Guards against two jobs fighting over the same USB interface claim. */
  private active: boolean = false;
  private verificationCancelled: boolean = false;
  private fileName: string = '';

  /** Set by the main screen and consumed by the confirmation screen. */
  pending: PendingSelection | null = null;

  static get(): JobStore {
    if (JobStore.instance === null) {
      JobStore.instance = new JobStore();
    }
    return JobStore.instance;
  }

  /** Supplies the context used for notifications and the continuous task. */
  attach(context: common.UIAbilityContext): void {
    NotificationController.get().attach(context);
  }

  addListener(listener: JobStateListener): void {
    this.listeners.push(listener);
  }

  removeListener(listener: JobStateListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  get jobState(): JobState {
    return this.state;
  }

  get jobStatus(): JobStatus {
    return this.status;
  }

  get isJobActive(): boolean {
    return this.active;
  }

  /** File name of the current job, needed when restarting after a reconnect. */
  get currentFileName(): string {
    return this.fileName;
  }

  get notificationsAllowed(): boolean {
    return NotificationController.get().notificationsAllowed;
  }

  private setState(state: JobState, status: JobStatus): void {
    this.state = state;
    this.status = status;
    const snapshot = status.copy();
    for (const listener of this.listeners) {
      listener(state, snapshot);
    }
  }

  // -------------------------------------------------------------------------
  // JobSink
  // -------------------------------------------------------------------------

  isVerificationCancelled(): boolean {
    return this.verificationCancelled;
  }

  /** Port of the SKIP_VERIFY broadcast: verification stops at the next chunk. */
  skipVerification(): void {
    this.verificationCancelled = true;
  }

  onProgress(processedBytes: number, totalBytes: number, speed: number, isVerifying: boolean): void {
    const next = this.status.copy();
    next.processedBytes = processedBytes;
    next.totalBytes = totalBytes;
    next.speed = speed;
    next.isVerifying = isVerifying;
    next.exception = null;
    this.setState(JobState.IN_PROGRESS, next);
    this.updateProgressNotification(next);
  }

  // -------------------------------------------------------------------------
  // Running a job
  // -------------------------------------------------------------------------

  /**
   * Starts a job and resolves once it has finished (successfully or not).
   *
   * Pages do not await this: the returned promise exists so a caller can tell when
   * the device has been released, matching upstream's rule that a new job is only
   * safe once the previous one has torn its USB connection down.
   */
  async startJob(
    imageUri: string,
    device: DeviceInfo,
    offset: number,
    verifyOnly: boolean,
    fileName: string,
  ): Promise<void> {
    if (this.active) {
      LOG.warn('Ignoring startJob: a job is already running');
      return;
    }
    this.active = true;
    this.verificationCancelled = false;
    this.fileName = fileName;

    const jobId = Math.floor(Math.random() * 0x7FFFFFFF);
    const started = new JobStatus();
    started.imageUri = imageUri;
    started.imageName = fileName;
    started.destDevice = device;
    started.jobId = jobId;
    started.isVerifying = verifyOnly;
    this.setState(JobState.IN_PROGRESS, started);

    const notifications = NotificationController.get();
    notifications.refreshAllowed();
    await notifications.cancel(jobId);
    await notifications.startKeepAlive();

    const request = new JobRequest();
    request.imageUri = imageUri;
    request.device = device;
    request.jobId = jobId;
    request.offset = offset;
    request.verifyOnly = verifyOnly;

    try {
      await new WorkerService(request, this).run();
      await this.reportSuccess(started);
    } catch (error) {
      await this.reportFailure(started, toEtchDroidException(error));
    } finally {
      this.active = false;
      await notifications.stopKeepAlive();
    }
  }

  private async reportSuccess(started: JobStatus): Promise<void> {
    const finished = this.status.copy();
    finished.processedBytes = finished.totalBytes;
    finished.speed = 0;
    finished.exception = null;
    this.setState(JobState.SUCCESS, finished);

    const notifications = NotificationController.get();
    await notifications.cancel(JOB_PROGRESS_NOTIFICATION_ID);
    await notifications.publishResult(
      started.jobId,
      stringByName('write_finished'),
      stringByName('success_notif_content_text', [this.fileName, started.destDevice.name]),
    );
  }

  private async reportFailure(started: JobStatus, exception: EtchDroidException): Promise<void> {
    LOG.error(`Job ${started.jobId} failed: ${exception.message}`);

    const failed = this.status.copy();
    failed.exception = exception;
    failed.speed = 0;
    const recoverable = exception instanceof RecoverableException;
    this.setState(recoverable ? JobState.RECOVERABLE_ERROR : JobState.FATAL_ERROR, failed);

    const notifications = NotificationController.get();
    await notifications.cancel(JOB_PROGRESS_NOTIFICATION_ID);
    await notifications.publishResult(
      started.jobId,
      stringByName(recoverable ? 'action_required' : 'write_failed'),
      stringByName(exception.uiMessageRes, exception.uiMessageParams),
    );
  }

  // -------------------------------------------------------------------------
  // Notifications
  // -------------------------------------------------------------------------

  private updateProgressNotification(status: JobStatus): void {
    const notifications = NotificationController.get();
    const deviceName = status.destDevice.name;
    const title = stringByName(
      status.isVerifying ? 'notification_verify_progress_title' : 'notification_write_progress_title',
    );

    let text: string;
    if (!notifications.notificationsAllowed) {
      text = stringByName('notification_write_no_notifications_text', [this.fileName, deviceName]);
    } else if (status.isVerifying) {
      text = stringByName('notification_verify_progress_content', [deviceName, this.fileName]);
    } else {
      text = stringByName('notification_write_progress_content', [this.fileName, deviceName]);
    }

    const percent = status.percent;
    const progress = percent >= 0
      ? `${toHrSize(status.processedBytes)} / ${toHrSize(status.totalBytes)} (${percent}%)`
      : toHrSize(status.processedBytes);
    const additional = status.speed > 0
      ? `${progress} \u2022 ${toHrSize(status.speed)}/s`
      : progress;

    notifications.publishProgress(JOB_PROGRESS_NOTIFICATION_ID, title, text, additional);
  }
}
