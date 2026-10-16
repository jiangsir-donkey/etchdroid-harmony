/*
 * Notification and continuous-task handling for a running job.
 *
 * Replaces upstream's two notification channels plus its PARTIAL_WAKE_LOCK:
 *
 *  - the progress notification maps to a normal text notification re-published
 *    at most once per second, the same cadence upstream uses;
 *  - the wake lock maps to a DATA_TRANSFER continuous task, which also keeps the
 *    process alive while the screen is off.
 *
 * Upstream's progress notification is a live view with a determinate progress
 * bar. HarmonyOS reserves NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW for live views the
 * system proxy creates, so a third-party app cannot publish one directly: progress
 * is reported in the notification text instead. The system posts its own ongoing
 * chip for the continuous task.
 */

import { common, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { Logger } from '../utils/Logger';
import { errorText } from '../utils/ErrorText';

const LOG = new Logger('Notifications');

/** Replaced on every update, so one job occupies exactly one progress slot. */
export const JOB_PROGRESS_NOTIFICATION_ID = 0xE7C40001;

export class NotificationController {
  private static instance: NotificationController | null = null;

  private context: common.UIAbilityContext | null = null;
  private allowed: boolean = true;
  private keepAliveRunning: boolean = false;
  private tapAgent: WantAgent | undefined = undefined;

  static get(): NotificationController {
    if (NotificationController.instance === null) {
      NotificationController.instance = new NotificationController();
    }
    return NotificationController.instance;
  }

  /** Caches the ability context, refreshes the toggle, and builds the tap agent. */
  attach(context: common.UIAbilityContext): void {
    this.context = context;
    this.refreshAllowed();
    this.prepareTapAgent(context);
  }

  /** Re-reads whether the user currently permits notifications. */
  refreshAllowed(): void {
    try {
      this.allowed = notificationManager.isNotificationEnabledSync();
    } catch (error) {
      // Some builds refuse the query to third-party apps; assume allowed rather
      // than silently dropping every progress update.
      LOG.warn(`Could not query notification state: ${errorText(error)}`);
      this.allowed = true;
    }
  }

  get notificationsAllowed(): boolean {
    return this.allowed;
  }

  // -------------------------------------------------------------------------
  // Continuous task (upstream's wake lock)
  // -------------------------------------------------------------------------

  /**
   * Requests a DATA_TRANSFER continuous task so the job survives the app losing
   * focus or the screen turning off. Failure is not fatal: the transfer still runs
   * while the app is in the foreground.
   */
  async startKeepAlive(): Promise<void> {
    const context = this.context;
    if (context === null || this.keepAliveRunning) {
      return;
    }
    try {
      const agent: WantAgent = await wantAgent.getWantAgent(new WantAgentInfoBuilder(context).info);
      await backgroundTaskManager.startBackgroundRunning(
        context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        agent,
      );
      this.keepAliveRunning = true;
      LOG.info('Continuous task started');
    } catch (error) {
      LOG.warn(`Failed to start continuous task: ${errorText(error)}`);
    }
  }

  /** Releases the continuous task. Safe to call when none is running. */
  async stopKeepAlive(): Promise<void> {
    const context = this.context;
    if (context === null || !this.keepAliveRunning) {
      return;
    }
    this.keepAliveRunning = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
    } catch (error) {
      LOG.warn(`Failed to stop continuous task: ${errorText(error)}`);
    }
  }

  // -------------------------------------------------------------------------
  // Notifications
  // -------------------------------------------------------------------------

  /** Publishes or replaces the ongoing job notification. */
  async publishProgress(id: number, title: string, text: string, additionalText: string): Promise<void> {
    const normal: notificationManager.NotificationBasicContent = {
      title: title,
      text: text,
      additionalText: additionalText,
    };
    await this.publish(id, normal, true);
  }

  /** Publishes a dismissible completion or failure notification. */
  async publishResult(id: number, title: string, text: string): Promise<void> {
    const normal: notificationManager.NotificationBasicContent = {
      title: title,
      text: text,
    };
    await this.publish(id, normal, false);
  }

  async cancel(id: number): Promise<void> {
    try {
      await notificationManager.cancel(id);
    } catch (error) {
      LOG.warn(`Failed to cancel notification ${id}: ${errorText(error)}`);
    }
  }

  private async publish(
    id: number,
    normal: notificationManager.NotificationBasicContent,
    ongoing: boolean,
  ): Promise<void> {
    if (!this.allowed) {
      return;
    }
    const content: notificationManager.NotificationContent = {
      notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
      normal: normal,
    };
    const request: notificationManager.NotificationRequest = {
      id: id,
      content: content,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      isOngoing: ongoing,
      tapDismissed: !ongoing,
    };
    const agent = this.tapAgent;
    if (agent !== undefined) {
      request.wantAgent = agent;
    }
    try {
      await notificationManager.publish(request);
    } catch (error) {
      LOG.warn(`Failed to publish notification: ${errorText(error)}`);
    }
  }

  /** Tapping any job notification reopens this ability. */
  private prepareTapAgent(context: common.UIAbilityContext): void {
    try {
      wantAgent.getWantAgent(new WantAgentInfoBuilder(context).info).then(
        (agent: WantAgent): void => {
          this.tapAgent = agent;
        },
        (error: Error): void => {
          LOG.warn(`Failed to build notification WantAgent: ${errorText(error)}`);
        },
      );
    } catch (error) {
      LOG.warn(`Could not build notification WantAgent: ${errorText(error)}`);
    }
  }
}

/**
 * Builds the WantAgentInfo literal in one typed place instead of inline at every
 * call site.
 */
class WantAgentInfoBuilder {
  readonly info: wantAgent.WantAgentInfo;

  constructor(context: common.UIAbilityContext) {
    const want: Want = {
      bundleName: context.abilityInfo.bundleName,
      abilityName: context.abilityInfo.name,
    };
    this.info = {
      wants: [want],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };
  }
}
