/*
 * Port of ui/ConfirmOperationActivity.kt.
 *
 * Shows what is about to be written and to which drive, asks for access to the
 * drive, and only then lets the write start. The "lay your device flat" step is
 * kept because a knock during a write is what upstream's accelerometer warning
 * exists to prevent.
 */

import { usbManager } from '@kit.BasicServicesKit';
import { AppSettings, ThemeMode } from '../AppSettings';
import { DeviceInfo, findMassStorageDevice } from '../massstorage/UsbMassStorageDevice';
import { JobStore, PendingSelection } from '../service/JobStore';
import { ImageSource } from '../service/ImageSource';
import { Palette } from '../ui/Theme';
import { DeviceWatcher } from '../utils/DeviceWatcher';
import { stringByName } from '../utils/Resources';
import { fileNameFromUri, toHrSize } from '../utils/Format';

@Entry
@Component
struct ConfirmPage {
  @State themeMode: ThemeMode = ThemeMode.SYSTEM;
  @State fileName: string = '';
  @State imageSize: number = -1;
  @State deviceName: string = '';
  @State vidpid: string = '';
  @State hasPermission: boolean = false;
  @State showLayFlatSheet: boolean = false;
  @State deviceMissing: boolean = false;

  private selection: PendingSelection | null = null;
  private watcher: DeviceWatcher = new DeviceWatcher();

  aboutToAppear(): void {
    this.themeMode = AppSettings.get().themeMode;
    const selection = JobStore.get().pending;
    if (selection === null) {
      this.toast(stringByName('no_image_uri_provided'));
      this.getUIContext().getRouter().back();
      return;
    }
    this.selection = selection;
    this.fileName = selection.fileName.length > 0
      ? selection.fileName
      : fileNameFromUri(selection.imageUri);
    this.deviceName = selection.device.name.length > 0
      ? selection.device.name
      : stringByName('unknown_device');
    this.vidpid = selection.device.vidpid;
    this.refreshPermission();
    this.readImageSize();

    this.watcher.start((devices: DeviceInfo[]): void => {
      this.deviceMissing = this.selection !== null
        && findMassStorageDevice(this.selection.device) === null;
    });
  }

  aboutToDisappear(): void {
    this.watcher.stop();
  }

  onBackPress(): boolean {
    if (this.showLayFlatSheet) {
      this.showLayFlatSheet = false;
      return true;
    }
    return false;
  }

  /** Opens the image once to read its size, as upstream's getFileSize does. */
  private readImageSize(): void {
    const selection = this.selection;
    if (selection === null) {
      return;
    }
    try {
      const source = ImageSource.open(selection.imageUri);
      this.imageSize = source.size;
      source.close();
    } catch (error) {
      this.imageSize = -1;
    }
  }

  private refreshPermission(): void {
    const selection = this.selection;
    if (selection === null) {
      return;
    }
    try {
      this.hasPermission = usbManager.hasRight(selection.device.deviceName);
    } catch (error) {
      this.hasPermission = false;
    }
  }

  /** Port of the Grant access button: Android's requestPermission, ArkTS's requestRight. */
  private async grantAccess(): Promise<void> {
    const selection = this.selection;
    if (selection === null) {
      return;
    }
    try {
      const granted: boolean = await usbManager.requestRight(selection.device.deviceName);
      this.hasPermission = granted;
      if (!granted) {
        this.toast(stringByName('permission_denied_for_usb_device', [selection.device.deviceName]));
      }
    } catch (error) {
      this.hasPermission = false;
      this.toast(stringByName('permission_denied_for_usb_device', [selection.device.deviceName]));
    }
  }

  /** Starts the job and hands over to the progress screen. */
  private startWrite(): void {
    const selection = this.selection;
    if (selection === null) {
      return;
    }
    if (findMassStorageDevice(selection.device) === null) {
      this.toast(stringByName('usb_device_was_unplugged'));
      this.getUIContext().getRouter().back();
      return;
    }

    const store = JobStore.get();
    store.pending = null;
    try {
      this.getUIContext().getRouter().replaceUrl({ url: 'pages/Progress' });
    } catch (error) {
      // The progress screen keeps rendering from the store either way.
    }
    store.startJob(selection.imageUri, selection.device, 0, false, this.fileName);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
    } catch (error) {
      // A missing toast is not worth failing an operation over.
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Row() {
          Text($r('app.string.confirm_operation'))
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(new Palette(this.themeMode).text)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 8 })

        if (this.deviceMissing) {
          Text(stringByName('usb_device_was_unplugged'))
            .fontSize(15)
            .fontColor(new Palette(this.themeMode).danger)
            .width('100%')
            .padding({ left: 20, right: 20, bottom: 8 })
        }

        Scroll() {
          Column() {
            this.infoCard(
              '💿',
              stringByName('image_to_write'),
              this.fileName,
              this.imageSize >= 0 ? toHrSize(this.imageSize) : '',
            )

            Text('⬇')
              .fontSize(28)
              .fontColor(new Palette(this.themeMode).textSecondary)
              .margin({ top: 4, bottom: 4 })

            this.infoCard(
              '🔌',
              stringByName('destination_usb_device'),
              this.deviceName,
              this.vidpid,
            )

            if (!this.hasPermission) {
              Button($r('app.string.grant_access'))
                .width('100%')
                .margin({ top: 16 })
                .backgroundColor(new Palette(this.themeMode).primary)
                .fontColor(new Palette(this.themeMode).onPrimary)
                .onClick(() => {
                  this.grantAccess();
                })
            } else {
              Row() {
                Text('✅').fontSize(16).margin({ right: 8 })
                Text($r('app.string.permission_granted'))
                  .fontSize(14)
                  .fontColor(new Palette(this.themeMode).success)
              }
              .width('100%')
              .margin({ top: 16 })
              .justifyContent(FlexAlign.Center)
            }

            Column() {
              Text('⚠️').fontSize(24)
              Text($r('app.string.be_careful'))
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(new Palette(this.themeMode).warning)
                .margin({ top: 4, bottom: 4 })
              Text($r('app.string.writing_the_image_will_erase'))
                .fontSize(14)
                .textAlign(TextAlign.Center)
                .fontColor(new Palette(this.themeMode).textSecondary)
            }
            .width('100%')
            .padding(16)
            .margin({ top: 20 })
            .backgroundColor(new Palette(this.themeMode).surfaceVariant)
            .borderRadius(16)
            .alignItems(HorizontalAlign.Center)
          }
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 16 })
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.TopStart)

        Row() {
          Button($r('app.string.cancel'))
            .layoutWeight(1)
            .backgroundColor(Color.Transparent)
            .fontColor(new Palette(this.themeMode).textSecondary)
            .onClick(() => {
              this.getUIContext().getRouter().back();
            })
          Button($r('app.string.write_image'))
            .layoutWeight(1)
            .backgroundColor(new Palette(this.themeMode).primary)
            .fontColor(new Palette(this.themeMode).onPrimary)
            .enabled(this.hasPermission && !this.deviceMissing)
            .onClick(() => {
              this.showLayFlatSheet = true;
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 8, bottom: 20 })
      }
      .width('100%')
      .height('100%')

      if (this.showLayFlatSheet) {
        this.layFlatSheet()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(new Palette(this.themeMode).background);
  }

  @Builder
  infoCard(icon: string, label: string, title: string, subtitle: string) {
    Row() {
      Text(icon).fontSize(30).margin({ right: 16 })
      Column() {
        Text(label)
          .fontSize(12)
          .fontColor(new Palette(this.themeMode).primary)
        Text(title)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(new Palette(this.themeMode).text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(12)
            .fontColor(new Palette(this.themeMode).textSecondary)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(new Palette(this.themeMode).surface)
    .borderRadius(16)
  }

  @Builder
  layFlatSheet() {
    Column() {
      Column() {
        Text(stringByName('lay_your_device_flat_no_accel'))
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .fontColor(new Palette(this.themeMode).text)
          .margin({ top: 8, bottom: 20 })
        Button($r('app.string.continue_'))
          .width('100%')
          .backgroundColor(new Palette(this.themeMode).primary)
          .fontColor(new Palette(this.themeMode).onPrimary)
          .onClick(() => {
            // Close the sheet before the job starts so a double tap cannot fire
            // two jobs that would fight over the USB interface claim.
            this.showLayFlatSheet = false;
            this.startWrite();
          })
      }
      .width('100%')
      .padding(24)
      .backgroundColor(new Palette(this.themeMode).surface)
      .borderRadius({ topLeft: 24, topRight: 24 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .backgroundColor('#66000000')
  }
}
