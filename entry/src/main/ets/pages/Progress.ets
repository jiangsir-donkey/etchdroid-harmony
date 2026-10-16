/*
 * Port of ui/ProgressActivity.kt.
 *
 * Three screens live here, as upstream: the job in progress (which also covers the
 * recoverable-error state, because upstream keeps writing once the drive comes
 * back), the success screen, and the fatal-error screen.
 *
 * The reconnect behaviour is the interesting part. Android re-registers a
 * BroadcastReceiver for ACTION_USB_DEVICE_ATTACHED and probes usbManager.deviceList
 * after a settle delay; both map onto DeviceWatcher, which polls the device list.
 * When the expected drive is present again the job restarts from where it stopped.
 */

import { usbManager } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { notificationManager } from '@kit.NotificationKit';
import { AppSettings, ThemeMode } from '../AppSettings';
import { JobState, JobStatus } from '../JobStatus';
import { findMassStorageDevice } from '../massstorage/UsbMassStorageDevice';
import { JobStore, JobStateListener } from '../service/JobStore';
import { NotificationController } from '../service/Notifications';
import { Palette } from '../ui/Theme';
import { abilityContext } from '../utils/AppContext';
import { stringByName } from '../utils/Resources';
import { toHrSize } from '../utils/Format';
import {
  EtchDroidException,
  NotEnoughSpaceException,
  ServiceTimeoutException,
  VerificationFailedException,
} from '../exceptions/Exceptions';

/** Upstream's LAST_NOTIFICATION_TIMEOUT: silence for this long means the job died. */
const SILENCE_TIMEOUT_MS = 11 * 1000;

/** Upstream's RESTART_SETTLE_DELAY_MS before probing for the re-attached drive. */
const RESTART_SETTLE_DELAY_MS = 3 * 1000;

@Entry
@Component
struct ProgressPage {
  @State themeMode: ThemeMode = ThemeMode.SYSTEM;
  @State jobState: JobState = JobState.IN_PROGRESS;
  @State status: JobStatus = new JobStatus();
  @State showNotificationsBanner: boolean = true;
  @State notificationsAllowed: boolean = true;
  @State showHowDidThisHappen: boolean = false;
  @State reconnectPending: boolean = false;

  private listener: JobStateListener | null = null;
  private silenceTimer: number = -1;
  private reconnectTimer: number = -1;
  private reconnectBusy: boolean = false;

  aboutToAppear(): void {
    this.themeMode = AppSettings.get().themeMode;
    this.showNotificationsBanner = AppSettings.get().showNotificationsBanner;
    NotificationController.get().refreshAllowed();
    this.notificationsAllowed = NotificationController.get().notificationsAllowed;
    this.keepScreenOn();

    // The store keeps the latest status, so a page that appears mid-job renders
    // real progress instead of waiting for the next update.
    this.jobState = JobStore.get().jobState;
    this.status = JobStore.get().jobStatus;

    this.listener = (state: JobState, status: JobStatus): void => {
      this.applyState(state, status);
    };
    JobStore.get().addListener(this.listener);
    this.applyState(this.jobState, this.status);
  }

  aboutToDisappear(): void {
    const listener = this.listener;
    if (listener !== null) {
      JobStore.get().removeListener(listener);
      this.listener = null;
    }
    this.clearSilenceTimer();
    this.stopReconnect();
  }

  /** Upstream ignores Back while a job is running, and so does this screen. */
  onBackPress(): boolean {
    if (this.jobState === JobState.IN_PROGRESS || this.jobState === JobState.RECOVERABLE_ERROR) {
      return true;
    }
    if (this.showHowDidThisHappen) {
      this.showHowDidThisHappen = false;
      return true;
    }
    return false;
  }

  private applyState(state: JobState, status: JobStatus): void {
    this.jobState = state;
    this.status = status;
    if (state === JobState.IN_PROGRESS) {
      this.armSilenceTimer();
    } else {
      this.clearSilenceTimer();
    }
    if (state === JobState.RECOVERABLE_ERROR) {
      this.startReconnect();
    } else {
      this.stopReconnect();
    }
  }

  private keepScreenOn(): void {
    const context = abilityContext();
    if (context === undefined) {
      return;
    }
    window.getLastWindow(context).then((win: window.Window): void => {
      win.setWindowKeepScreenOn(true).catch((): void => {
        // Losing this only dims the screen; the job is unaffected.
      });
    }).catch((): void => {
      // As above.
    });
  }

  // -------------------------------------------------------------------------
  // Silence watchdog
  // -------------------------------------------------------------------------

  /**
   * Upstream arms an 11 s timer on every job update: if the service stops talking
   * the write is assumed lost, which is what happens when an OTG port browns out.
   */
  private armSilenceTimer(): void {
    this.clearSilenceTimer();
    this.silenceTimer = setTimeout((): void => {
      this.silenceTimer = -1;
      if (this.jobState !== JobState.IN_PROGRESS) {
        return;
      }
      const timedOut = this.status.copy();
      timedOut.exception = new ServiceTimeoutException();
      this.jobState = JobState.FATAL_ERROR;
      this.status = timedOut;
    }, SILENCE_TIMEOUT_MS);
  }

  private clearSilenceTimer(): void {
    if (this.silenceTimer !== -1) {
      clearTimeout(this.silenceTimer);
      this.silenceTimer = -1;
    }
  }

  // -------------------------------------------------------------------------
  // Reconnect after a recoverable error
  // -------------------------------------------------------------------------

  private startReconnect(): void {
    if (this.reconnectTimer !== -1) {
      return;
    }
    this.reconnectPending = true;
    this.reconnectBusy = false;
    // Polling starts after the settle delay, which also paces retries: a failed
    // restart re-enters this screen and would otherwise hammer a choking drive.
    this.reconnectTimer = setInterval((): void => {
      this.attemptReconnect();
    }, RESTART_SETTLE_DELAY_MS);
  }

  private stopReconnect(): void {
    if (this.reconnectTimer !== -1) {
      clearInterval(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    this.reconnectPending = false;
    this.reconnectBusy = false;
  }

  private async attemptReconnect(): Promise<void> {
    if (this.reconnectBusy) {
      return;
    }
    this.reconnectBusy = true;
    try {
      const store = JobStore.get();
      const current = store.jobStatus;
      const info = current.destDevice;
      const device = findMassStorageDevice(info);
      if (device === null) {
        // Not plugged back in yet; keep waiting.
        return;
      }
      if (!usbManager.hasRight(device.deviceName)) {
        const granted = await usbManager.requestRight(device.deviceName);
        if (!granted) {
          this.toast(stringByName('permission_denied_for_usb_device', [device.deviceName]));
          return;
        }
      }

      this.stopReconnect();
      this.toast(stringByName('usb_device_reconnected_resuming'));
      // Resume where the transfer stopped and repeat the same phase it was in,
      // exactly as upstream's AutoJobRestarter does.
      store.startJob(
        current.imageUri,
        info,
        current.processedBytes,
        current.isVerifying,
        current.imageName,
      );
    } catch (error) {
      // The drive disappeared between the scan and the permission request.
    } finally {
      this.reconnectBusy = false;
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
    } catch (error) {
      // A missing toast is not worth failing an operation over.
    }
  }

  private goToStart(): void {
    this.stopReconnect();
    try {
      this.getUIContext().getRouter().back({ url: 'pages/Index' });
    } catch (error) {
      try {
        this.getUIContext().getRouter().replaceUrl({ url: 'pages/Index' });
      } catch (nested) {
        // Nothing else can be done from here.
      }
    }
  }

  private exception(): EtchDroidException | null {
    return this.status.exception;
  }

  private exceptionText(): string {
    const exception = this.exception();
    if (exception === null) {
      return stringByName('an_unknown_error_occurred', ['']);
    }
    return stringByName(exception.uiMessageRes, exception.uiMessageParams);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        if (this.jobState === JobState.SUCCESS) {
          this.successView();
        } else if (this.jobState === JobState.FATAL_ERROR) {
          this.fatalErrorView();
        } else {
          this.inProgressView();
        }
      }
      .width('100%')
      .height('100%')

      if (this.jobState === JobState.RECOVERABLE_ERROR) {
        this.reconnectDialog();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(new Palette(this.themeMode).background);
  }

  // -------------------------------------------------------------------------
  // In progress
  // -------------------------------------------------------------------------

  @Builder
  inProgressView() {
    Column() {
      Column() {
        Text(this.status.isVerifying
          ? stringByName('verifying_image')
          : stringByName('writing_image'))
          .fontSize(26)
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .fontColor(new Palette(this.themeMode).text)
        Text($r('app.string.please_avoid_using_your_device'))
          .fontSize(16)
          .textAlign(TextAlign.Center)
          .fontColor(new Palette(this.themeMode).textSecondary)
          .margin({ top: 8 })
      }
      .padding({ top: 48, bottom: 24, left: 16, right: 16 })

      Column() {
        Text(this.status.isVerifying ? '🔍' : '💾')
          .fontSize(110)
        if (this.showNotificationsBanner && !this.notificationsAllowed) {
          Column() {
            Text($r('app.string.would_you_like_to_be_notified'))
              .fontSize(14)
              .textAlign(TextAlign.Center)
              .fontColor(new Palette(this.themeMode).text)
              .margin({ bottom: 12 })
            Row() {
              Button($r('app.string.no_thanks'))
                .layoutWeight(1)
                .backgroundColor(Color.Transparent)
                .fontColor(new Palette(this.themeMode).textSecondary)
                .onClick(() => {
                  this.dismissNotificationsBanner();
                })
              Button($r('app.string.sure'))
                .layoutWeight(1)
                .backgroundColor(new Palette(this.themeMode).primary)
                .fontColor(new Palette(this.themeMode).onPrimary)
                .onClick(() => {
                  this.requestNotifications();
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .margin({ top: 8 })
          .backgroundColor(new Palette(this.themeMode).surfaceVariant)
          .borderRadius(16)
        }
      }
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 24, right: 24 })

      Blank()

      Column() {
        Row() {
          Text(this.status.isVerifying ? stringByName('verifying') : stringByName('copying'))
            .fontSize(14)
            .fontColor(new Palette(this.themeMode).textSecondary)
          Text(` ${this.status.isVerifying ? this.status.destDevice.name : this.status.imageName}`)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(new Palette(this.themeMode).text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)

        Row() {
          Text(this.status.isVerifying ? stringByName('against') : stringByName('to'))
            .fontSize(14)
            .fontColor(new Palette(this.themeMode).textSecondary)
          Text(` ${this.status.isVerifying ? this.status.imageName : this.status.destDevice.name}`)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(new Palette(this.themeMode).text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)

        Text(this.status.percent >= 0
          ? `${toHrSize(this.status.processedBytes)} / ${toHrSize(this.status.totalBytes)} ${this.status.isVerifying ? 'verified' : 'written'}, ${toHrSize(this.status.speed)}/s`
          : stringByName('getting_ready'))
          .fontSize(15)
          .textAlign(TextAlign.Center)
          .fontColor(new Palette(this.themeMode).text)
          .width('100%')
          .margin({ top: 8 })

        if (this.status.percent >= 0) {
          Progress({ value: this.status.percent, total: 100, type: ProgressType.Linear })
            .color(new Palette(this.themeMode).primary)
            .width('100%')
            .margin({ top: 24 })
        } else {
          // Upstream's indeterminate linear bar; ArkUI's indeterminate indicator is
          // a spinner, which carries the same "working, length unknown" meaning.
          LoadingProgress()
            .width(40)
            .height(40)
            .color(new Palette(this.themeMode).primary)
            .margin({ top: 24 })
        }

        if (this.status.isVerifying) {
          Button($r('app.string.skip_verification'))
            .width('100%')
            .margin({ top: 24 })
            .backgroundColor(Color.Transparent)
            .fontColor(new Palette(this.themeMode).primary)
            .onClick(() => {
              JobStore.get().skipVerification();
            })
        }
      }
      .width('100%')
      .padding({ left: 32, right: 32, bottom: 40 })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }

  private dismissNotificationsBanner(): void {
    AppSettings.get().showNotificationsBanner = false;
    this.showNotificationsBanner = false;
  }

  private async requestNotifications(): Promise<void> {
    const context = abilityContext();
    if (context === undefined) {
      return;
    }
    try {
      await notificationManager.requestEnableNotification(context);
    } catch (error) {
      // The user declined; the banner stays until it is dismissed.
    }
    NotificationController.get().refreshAllowed();
    this.notificationsAllowed = NotificationController.get().notificationsAllowed;
  }

  // -------------------------------------------------------------------------
  // Reconnect dialog
  // -------------------------------------------------------------------------

  @Builder
  reconnectDialog() {
    Column() {
      Column() {
        Text('🔌').fontSize(40)
        Text(this.exceptionText())
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .fontColor(new Palette(this.themeMode).text)
          .margin({ top: 12 })
        Text($r('app.string.to_recover_unplug'))
          .fontSize(14)
          .textAlign(TextAlign.Center)
          .fontColor(new Palette(this.themeMode).textSecondary)
          .margin({ top: 12 })
        Text($r('app.string.representation_of_the_required_steps'))
          .fontSize(13)
          .textAlign(TextAlign.Center)
          .fontColor(new Palette(this.themeMode).textSecondary)
          .margin({ top: 8 })

        if (this.reconnectPending) {
          Row() {
            LoadingProgress().width(20).height(20).color(new Palette(this.themeMode).primary)
            Text(stringByName('usb_device_reconnected_resuming'))
              .fontSize(13)
              .fontColor(new Palette(this.themeMode).textSecondary)
              .margin({ left: 8 })
          }
          .margin({ top: 16 })
        }

        if (this.showHowDidThisHappen) {
          Column() {
            Text($r('app.string.perhaps_your_usb_port_is_dirty'))
              .fontSize(13)
              .fontColor(new Palette(this.themeMode).textSecondary)
              .margin({ bottom: 8 })
            Text($r('app.string.usb_drives_are_unreliable'))
              .fontSize(13)
              .fontColor(new Palette(this.themeMode).textSecondary)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 16 })
          .padding(12)
          .backgroundColor(new Palette(this.themeMode).surfaceVariant)
          .borderRadius(12)
        }

        Row() {
          Button($r('app.string.how_did_this_happen'))
            .layoutWeight(1)
            .backgroundColor(Color.Transparent)
            .fontColor(new Palette(this.themeMode).primary)
            .onClick(() => {
              this.showHowDidThisHappen = !this.showHowDidThisHappen;
            })
          Button($r('app.string.start_over'))
            .layoutWeight(1)
            .backgroundColor(Color.Transparent)
            .fontColor(new Palette(this.themeMode).textSecondary)
            .onClick(() => {
              this.goToStart();
            })
        }
        .width('100%')
        .margin({ top: 16 })
      }
      .alignItems(HorizontalAlign.Center)
      .width('100%')
      .backgroundColor(new Palette(this.themeMode).surface)
      .borderRadius(20)
      .padding(20)
      .margin({ left: 24, right: 24, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#66000000')
  }

  // -------------------------------------------------------------------------
  // Success
  // -------------------------------------------------------------------------

  @Builder
  successView() {
    Column() {
      Text($r('app.string.image_written_successfully'))
        .fontSize(26)
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .fontColor(new Palette(this.themeMode).text)
        .padding({ top: 48, left: 24, right: 24 })

      Text('✅')
        .fontSize(140)
        .margin({ top: 32, bottom: 32 })

      Row() {
        Button($r('app.string.support_the_project'))
          .backgroundColor(Color.Transparent)
          .fontColor(new Palette(this.themeMode).primary)
          .onClick(() => {
            this.openUrl('https://etchdroid.app/donate/');
          })
        Button($r('app.string.star_on_github'))
          .backgroundColor(Color.Transparent)
          .fontColor(new Palette(this.themeMode).primary)
          .margin({ left: 8 })
          .onClick(() => {
            this.openUrl('https://github.com/EtchDroid/EtchDroid');
          })
      }
      .margin({ bottom: 8 })

      Button($r('app.string.write_another_image'))
        .backgroundColor(new Palette(this.themeMode).primary)
        .fontColor(new Palette(this.themeMode).onPrimary)
        .onClick(() => {
          this.goToStart();
        })

      Blank()

      Column() {
        Text($r('app.string.got_an_unsupported_drive_notification'))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .textAlign(TextAlign.Center)
          .fontColor(new Palette(this.themeMode).textSecondary)
          .margin({ bottom: 8 })
        Text(stringByName('it_s_safe_to_ignore', [stringByName('learn_what_it_means')]))
          .fontSize(13)
          .textAlign(TextAlign.Center)
          .fontColor(new Palette(this.themeMode).textSecondary)
      }
      .width('100%')
      .padding(16)
      .margin({ left: 16, right: 16, bottom: 16 })
      .backgroundColor(new Palette(this.themeMode).surfaceVariant)
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }

  // -------------------------------------------------------------------------
  // Fatal error
  // -------------------------------------------------------------------------

  @Builder
  fatalErrorView() {
    Column() {
      Text($r('app.string.there_was_an_error'))
        .fontSize(26)
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .fontColor(new Palette(this.themeMode).text)
        .padding({ top: 48, left: 24, right: 24 })

      Text(this.exceptionText())
        .fontSize(17)
        .textAlign(TextAlign.Center)
        .fontColor(new Palette(this.themeMode).textSecondary)
        .padding({ top: 16, left: 24, right: 24 })

      if (!this.isOutOfSpace()) {
        Text($r('app.string.please_report_fatal_issue'))
          .fontSize(14)
          .textAlign(TextAlign.Center)
          .fontColor(new Palette(this.themeMode).textSecondary)
          .padding({ top: 12, left: 24, right: 24 })
      }

      Text('❌')
        .fontSize(140)
        .margin({ top: 16, bottom: 16 })

      Blank()

      Row() {
        Button($r('app.string.view_github_issues'))
          .backgroundColor(Color.Transparent)
          .fontColor(new Palette(this.themeMode).primary)
          .onClick(() => {
            this.openUrl('https://github.com/etchdroid/etchdroid/issues');
          })
        if (this.status.exception instanceof VerificationFailedException) {
          Button($r('app.string.try_again'))
            .backgroundColor(Color.Transparent)
            .fontColor(new Palette(this.themeMode).primary)
            .margin({ left: 8 })
            .onClick(() => {
              this.retryVerification();
            })
        }
      }
      .margin({ bottom: 12 })

      Button($r('app.string.start_over'))
        .backgroundColor(new Palette(this.themeMode).primary)
        .fontColor(new Palette(this.themeMode).onPrimary)
        .margin({ bottom: 32 })
        .onClick(() => {
          this.goToStart();
        })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }

  private isOutOfSpace(): boolean {
    return this.status.exception instanceof NotEnoughSpaceException;
  }

  /** Upstream offers Try again for a device that no longer matches the image. */
  private retryVerification(): void {
    const current = this.status;
    JobStore.get().startJob(current.imageUri, current.destDevice, 0, false, current.imageName);
  }

  private openUrl(url: string): void {
    const context = abilityContext();
    if (context === undefined) {
      return;
    }
    context.openLink(url, { appLinkingOnly: false }).catch((): void => {
      this.toast(url);
    });
  }
}
