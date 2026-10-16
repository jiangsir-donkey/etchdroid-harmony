/*
 * Port of ui/MainActivity.kt - the start screen.
 *
 * Pick an image, pick a drive, then confirm. Two upstream behaviours are kept
 * verbatim because they protect the user: a file whose name looks like a Windows
 * ISO is questioned first, and a single attached drive skips the picker.
 */

import { picker } from '@kit.CoreFileKit';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { AppSettings, ThemeMode } from '../AppSettings';
import { DeviceInfo } from '../massstorage/UsbMassStorageDevice';
import { JobStore, PendingSelection } from '../service/JobStore';
import { Palette } from '../ui/Theme';
import { DeviceWatcher } from '../utils/DeviceWatcher';
import { abilityContext } from '../utils/AppContext';
import { stringByName } from '../utils/Resources';
import { fileNameFromUri } from '../utils/Format';
import { errorText } from '../utils/ErrorText';
import { Logger } from '../utils/Logger';

const LOG = new Logger('Index');

/** Suffixes offered in the picker, covering every image type upstream accepts. */
const IMAGE_SUFFIXES: string[] = [
  '.iso', '.img', '.bin', '.raw', '.dmg', '.wic', '.vhd', '.vhdm', '.xz', '.gz', '.zip', '.tar',
];

/** A picked image awaiting a destination drive. */
class PickedImage {
  uri: string = '';
  fileName: string = '';
}

/**
 * Public repository holding the source of this port.
 *
 * The GPLv3 requires anyone who distributes this app to offer its Corresponding
 * Source, so the link is shown in the app. REPLACE THIS before publishing.
 */
const SOURCE_REPO_URL = 'https://gitee.com/ditney/etchdroid-harmony';

@Entry
@Component
struct Index {
  @State devices: DeviceInfo[] = [];
  @State themeMode: ThemeMode = ThemeMode.SYSTEM;
  @State showDeviceSheet: boolean = false;
  @State showSupportedSheet: boolean = false;
  @State showSettingsSheet: boolean = false;
  @State showWindowsAlert: boolean = false;
  @State picked: PickedImage | null = null;
  /** False when the USB host service cannot be reached at all (e.g. an emulator). */
  @State usbAvailable: boolean = true;

  private watcher: DeviceWatcher = new DeviceWatcher();

  aboutToAppear(): void {
    this.themeMode = AppSettings.get().themeMode;
    try {
      this.watcher.start((devices: DeviceInfo[], usbAvailable: boolean): void => {
        this.devices = devices;
        this.usbAvailable = usbAvailable;
      });
    } catch (error) {
      // The start screen must open even when USB cannot be reached.
      LOG.warn(`Could not start watching for USB drives: ${errorText(error)}`);
      this.usbAvailable = false;
    }
  }

  aboutToDisappear(): void {
    this.watcher.stop();
  }

  /** Upstream's fail-open Windows check, run against the picker's file name. */
  private looksLikeWindowsImage(fileName: string): boolean {
    try {
      const lower = fileName.toLowerCase();
      return lower.includes('windows') || lower.startsWith('win');
    } catch (error) {
      return false;
    }
  }

  /** Hands an external link to the browser; a missing browser is not an error. */
  private openUrl(url: string): void {
    const context = abilityContext();
    if (context === undefined) {
      return;
    }
    context.openLink(url, { appLinkingOnly: false }).catch((): void => {
      // Nothing useful to do if no browser can handle it.
    });
  }

  private async pickImage(): Promise<void> {
    const context = abilityContext();
    if (context === undefined) {
      return;
    }
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = IMAGE_SUFFIXES;
      const uris: string[] = await new picker.DocumentViewPicker(context).select(options);
      if (uris.length === 0) {
        return;
      }
      this.openImage(uris[0], false);
    } catch (error) {
      // Cancelling the picker surfaces as an error too, and the platform does not
      // give it a stable code, so a cancelled pick is simply a no-op.
    }
  }

  /**
   * Registers the chosen image. With exactly one drive attached upstream goes
   * straight to confirmation; otherwise the drive sheet opens.
   */
  private openImage(uri: string, userSaysYolo: boolean): void {
    const fileName = fileNameFromUri(uri);
    if (!userSaysYolo && this.looksLikeWindowsImage(fileName)) {
      const pending = new PickedImage();
      pending.uri = uri;
      pending.fileName = fileName;
      this.picked = pending;
      this.showWindowsAlert = true;
      return;
    }

    if (this.devices.length === 1) {
      this.launchConfirmation(uri, fileName, this.devices[0]);
      return;
    }

    const pending = new PickedImage();
    pending.uri = uri;
    pending.fileName = fileName;
    this.picked = pending;
    this.showDeviceSheet = true;
  }

  private launchConfirmation(uri: string, fileName: string, device: DeviceInfo): void {
    const selection = new PendingSelection();
    selection.imageUri = uri;
    selection.fileName = fileName;
    selection.device = device;
    JobStore.get().pending = selection;
    this.showDeviceSheet = false;
    this.showWindowsAlert = false;
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/Confirm' });
    } catch (error) {
      // Staying on the start screen is the only sane fallback.
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.mainScreen();
      if (this.showDeviceSheet) {
        this.deviceSheet();
      }
      if (this.showSupportedSheet) {
        this.supportedSheet();
      }
      if (this.showSettingsSheet) {
        this.settingsSheet();
      }
      if (this.showWindowsAlert) {
        this.windowsAlert();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(new Palette(this.themeMode).background);
  }

  @Builder
  mainScreen() {
    Column() {
      Row() {
        Text($r('app.string.app_name'))
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor(new Palette(this.themeMode).text)
        Blank()
        Button($r('app.string.whats_supported'))
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor(new Palette(this.themeMode).primary)
          .onClick(() => {
            this.showSupportedSheet = true;
          })
        Button('⚙')
          .fontSize(20)
          .backgroundColor(Color.Transparent)
          .fontColor(new Palette(this.themeMode).textSecondary)
          .onClick(() => {
            this.showSettingsSheet = true;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12 })

      Blank()

      Column() {
        Text('💿')
          .fontSize(110)
          .margin({ bottom: 40 })
        Button($r('app.string.write_an_image'))
          .fontSize(20)
          .height(56)
          .width(240)
          .backgroundColor(new Palette(this.themeMode).primary)
          .fontColor(new Palette(this.themeMode).onPrimary)
          .onClick(() => {
            this.pickImage();
          })
      }
      .alignItems(HorizontalAlign.Center)

      Blank()

      Text(this.usbAvailable
        ? (this.devices.length > 0
          ? `${this.devices.length} ${stringByName('devices').toLowerCase()}`
          : stringByName('connect_a_usb_drive'))
        : stringByName('usb_host_unavailable'))
        .fontSize(14)
        .textAlign(TextAlign.Center)
        .fontColor(this.usbAvailable
          ? new Palette(this.themeMode).textSecondary
          : new Palette(this.themeMode).warning)
        .padding({ left: 24, right: 24 })
        .margin({ bottom: 24 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  sheetHeader(title: string) {
    Row() {
      Text(title)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(new Palette(this.themeMode).text)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 20, right: 12, top: 16, bottom: 8 })
  }

  @Builder
  deviceSheet() {
    Column() {
      Column() {
        this.sheetHeader(this.devices.length > 0
          ? stringByName('select_a_usb_drive')
          : stringByName('connect_a_usb_drive'))

        if (this.devices.length > 0 && this.picked !== null) {
          List() {
            ForEach(this.devices, (device: DeviceInfo) => {
              ListItem() {
                Row() {
                  Text('🔌').fontSize(24).margin({ right: 16 })
                  Column() {
                    Text(device.name)
                      .fontSize(16)
                      .fontColor(new Palette(this.themeMode).text)
                    Text(device.vidpid)
                      .fontSize(12)
                      .fontStyle(FontStyle.Italic)
                      .fontColor(new Palette(this.themeMode).textSecondary)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')
                .padding(16)
              }
              .onClick(() => {
                const picked = this.picked;
                if (picked !== null) {
                  this.launchConfirmation(picked.uri, picked.fileName, device);
                }
              })
            }, (device: DeviceInfo) => device.deviceName)
          }
          .width('100%')
          .constraintSize({ maxHeight: 320 })
        } else {
          Column() {
            Text(this.usbAvailable ? '🔍' : '⚠️').fontSize(48)
            Text(this.usbAvailable
              ? stringByName('looking_for_usb_drives')
              : stringByName('usb_host_unavailable'))
              .fontSize(14)
              .textAlign(TextAlign.Center)
              .fontColor(this.usbAvailable
                ? new Palette(this.themeMode).textSecondary
                : new Palette(this.themeMode).warning)
              .margin({ top: 12 })
          }
          .width('100%')
          .padding({ top: 8, bottom: 24 })
        }

        LoadingProgress().width(28).height(28).color(new Palette(this.themeMode).primary)

        Button($r('app.string.cancel'))
          .width('100%')
          .margin({ top: 16 })
          .backgroundColor(Color.Transparent)
          .fontColor(new Palette(this.themeMode).textSecondary)
          .onClick(() => {
            this.showDeviceSheet = false;
            this.picked = null;
          })
      }
      .width('100%')
      .backgroundColor(new Palette(this.themeMode).surface)
      .borderRadius({ topLeft: 24, topRight: 24 })
      .padding({ bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .backgroundColor('#66000000')
  }

  @Builder
  windowsAlert() {
    Column() {
      Column() {
        Text($r('app.string.is_this_a_windows_iso'))
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(new Palette(this.themeMode).text)
          .margin({ bottom: 12 })
        Text($r('app.string.a_regular_windows_iso_won_t_work'))
          .fontSize(15)
          .fontColor(new Palette(this.themeMode).textSecondary)
          .margin({ bottom: 20 })
        Row() {
          Button($r('app.string.cancel'))
            .layoutWeight(1)
            .backgroundColor(Color.Transparent)
            .fontColor(new Palette(this.themeMode).textSecondary)
            .onClick(() => {
              this.showWindowsAlert = false;
              this.picked = null;
            })
          Button($r('app.string.continue_anyway'))
            .layoutWeight(1)
            .backgroundColor(new Palette(this.themeMode).primary)
            .fontColor(new Palette(this.themeMode).onPrimary)
            .onClick(() => {
              const picked = this.picked;
              this.showWindowsAlert = false;
              if (picked !== null) {
                this.openImage(picked.uri, true);
              }
            })
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
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

  @Builder
  supportRow(description: string, status: number) {
    Row() {
      Text(status === 0 ? '✅' : (status === 1 ? '❓' : '❌'))
        .fontSize(16)
        .margin({ right: 10 })
      Text(description)
        .fontSize(15)
        .fontColor(new Palette(this.themeMode).text)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  supportedSheet() {
    Column() {
      Column() {
        this.sheetHeader(stringByName('whats_supported'))
        Scroll() {
          Column() {
            Text($r('app.string.supported_devices_and_images'))
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(new Palette(this.themeMode).text)
              .width('100%')
              .margin({ top: 8, bottom: 8 })
            Text($r('app.string.devices'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(new Palette(this.themeMode).primary)
              .width('100%')
            this.supportRow(stringByName('usb_flash_drives'), 0)
            this.supportRow(stringByName('memory_cards_using_a_usb_adapter'), 0)
            this.supportRow(stringByName('usb_hard_drives_ssds_some_might_work'), 1)
            this.supportRow(stringByName('usb_docks_and_hubs_might_have_power_issues'), 1)
            this.supportRow(stringByName('memory_cards_using_the_internal_slot'), 2)
            this.supportRow(stringByName('optical_disk_drives'), 2)
            this.supportRow(stringByName('floppy_disk_drives'), 2)
            this.supportRow(stringByName('any_thunderbolt_only_device'), 2)
            this.supportRow(stringByName('very_large_drives_2tb'), 2)

            Text($r('app.string.disk_images'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(new Palette(this.themeMode).primary)
              .width('100%')
              .margin({ top: 16 })
            this.supportRow(stringByName('microsoft_windows_isos_any_version'), 0)
            this.supportRow(stringByName('community_windows_images'), 1)
            this.supportRow(stringByName('arch_linux_ubuntu_debian_fedora_pop_os_linux_mint_freebsd_etc'), 0)
            this.supportRow(stringByName('other_modern_gnu_linux_and_bsd_distributions_live_isos'), 0)
            this.supportRow(stringByName('older_gnu_linux_distributions_isos_2010'), 1)
            this.supportRow(stringByName('raspberry_pi_sd_card_images_unzip_first'), 0)
            this.supportRow(stringByName('any_other_image_that_works_with_balena_etcher_or_dd'), 1)
            this.supportRow(stringByName('apple_dmg_disk_images'), 2)

            Text(stringByName('support_for_dmg_images_was_removed', ['GitHub']))
              .fontSize(13)
              .fontColor(new Palette(this.themeMode).textSecondary)
              .width('100%')
              .margin({ top: 16, bottom: 24 })
          }
          .width('100%')
          .padding({ left: 20, right: 20 })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.TopStart)
      }
      .width('100%')
      .height('80%')
      .backgroundColor(new Palette(this.themeMode).surface)
      .borderRadius({ topLeft: 24, topRight: 24 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .backgroundColor('#66000000')
  }

  @Builder
  settingsSheet() {
    Column() {
      Column() {
        this.sheetHeader(stringByName('style'))
        Scroll() {
          Column() {
            Text(stringByName('device_setting'))
              .fontSize(15)
              .fontColor(new Palette(this.themeMode).text)
              .width('100%')
              .padding({ top: 8, bottom: 4 })
              .onClick(() => {
                this.applyTheme(ThemeMode.SYSTEM);
              })
            Text(stringByName('light'))
              .fontSize(15)
              .fontColor(new Palette(this.themeMode).text)
              .width('100%')
              .padding({ top: 8, bottom: 4 })
              .onClick(() => {
                this.applyTheme(ThemeMode.LIGHT);
              })
            Text(stringByName('dark'))
              .fontSize(15)
              .fontColor(new Palette(this.themeMode).text)
              .width('100%')
              .padding({ top: 8, bottom: 4 })
              .onClick(() => {
                this.applyTheme(ThemeMode.DARK);
              })

            Text(stringByName('about'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(new Palette(this.themeMode).primary)
              .width('100%')
              .margin({ top: 24, bottom: 4 })
            Text(stringByName('developed_by', ['depau']))
              .fontSize(13)
              .fontColor(new Palette(this.themeMode).textSecondary)
              .width('100%')
              .margin({ bottom: 8 })
            Text(stringByName('unofficial_port_notice'))
              .fontSize(12)
              .fontColor(new Palette(this.themeMode).warning)
              .width('100%')
              .margin({ bottom: 12 })
            Button($r('app.string.source_code'))
              .fontSize(13)
              .backgroundColor(Color.Transparent)
              .fontColor(new Palette(this.themeMode).primary)
              .padding({ left: 0, right: 0 })
              .margin({ bottom: 16 })
              .onClick(() => {
                this.openUrl(SOURCE_REPO_URL);
              })

            Button($r('app.string.cancel'))
              .width('100%')
              .backgroundColor(Color.Transparent)
              .fontColor(new Palette(this.themeMode).textSecondary)
              .onClick(() => {
                this.showSettingsSheet = false;
              })
          }
          .width('100%')
          .padding({ left: 20, right: 20 })
          .alignItems(HorizontalAlign.Start)
        }
        .constraintSize({ maxHeight: 420 })
        .width('100%')
      }
      .width('100%')
      .backgroundColor(new Palette(this.themeMode).surface)
      .borderRadius({ topLeft: 24, topRight: 24 })
      .padding({ bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .backgroundColor('#66000000')
  }

  private applyTheme(mode: ThemeMode): void {
    AppSettings.get().themeMode = mode;
    this.themeMode = mode;
    // Keep system-owned surfaces (toasts, the picker, dialogs) consistent with the
    // in-app choice, the same way upstream's MaterialTheme override does.
    const context = abilityContext();
    if (context !== undefined) {
      try {
        context.setColorMode(mode === ThemeMode.DARK
          ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
          : (mode === ThemeMode.LIGHT
            ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
            : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET));
      } catch (error) {
        // Not fatal: only the app's own palette changes.
      }
    }
  }
}
