# EtchDroid for HarmonyOS

An unofficial ArkTS port of EtchDroid to HarmonyOS (OpenHarmony / HarmonyOS NEXT).

> **This directory is community-maintained.** It is **not** built or tested by
> this repository's CI, and it does not affect the Gradle build or the Android
> app in any way. Bugs and questions about it belong to its author, not to the
> EtchDroid maintainers - see [Maintenance](#maintenance).

## What it does

The same job as the Android app in [`../app`](../app): write a raw disk image
(ISO or IMG) to a USB drive over USB-OTG, so a phone or tablet can turn a USB
stick into a bootable Linux or Raspberry Pi drive.

The core is the same idea as upstream: a hand-written USB Mass Storage
implementation (SCSI Bulk-Only Transport) talking straight to the raw block
device. No mounting, no kernel filesystem drivers, no root.

## Status

| | |
| --- | --- |
| Build | `./build.sh all` produces a signed HAP and passes `verify-app` |
| HarmonyOS emulator | Launches; the full pick-image to pick-drive flow renders (API 21) |
| Real USB hardware | **Not verified yet.** The emulator has no USB host service, so the write path needs a real USB-OTG device |
| Telemetry / ads / network | None. `ohos.permission.INTERNET` is not requested |
| Languages | English and Simplified Chinese, following the system locale |

Please treat the write path as **beta** until it has been exercised against real
drives by more people than its author.

## Requirements

- HarmonyOS Command Line Tools (devkit with `hvigorw` and `hdc`), or DevEco Studio
- JDK 17 (used by the SDK signing tool)
- `python3`

`build.sh` looks for the command line tools under
`~/downloads/commandline-tools-linux-x64-*/command-line-tools` and can be pointed
elsewhere with `HOS_CLI=/path/to/command-line-tools`.

## Build

```bash
cd harmonyos
HVIGOR_USER_HOME=/tmp/etchdroid-hvigor-home ./build.sh all
```

| Subcommand | Effect |
| --- | --- |
| `hap` | Build an unsigned HAP with hvigor |
| `sign` | Sign the HAP with the SDK OpenHarmony test certificate and verify it |
| `all` | `hap` + `sign` (default) |
| `clean` | Remove build trees, `dist/` and the ASCII mirror |

The result is `dist/etchdroid-signed.hap`. `HVIGOR_USER_HOME` is mandatory.

**Why the mirror:** hvigor rejects project paths containing non-ASCII
characters, and this port was developed under a path containing non-ASCII
characters. So `build.sh` mirrors the sources to an ASCII path under `/tmp` and
builds there. Override the mirror with `ETCHDROID_MIRROR=/some/ascii/dir`.

### Installing on a device

```bash
hdc install dist/etchdroid-signed.hap
```

The build is signed with the SDK **test** certificate, which is only good for
debugging on a device with developer mode enabled. Shipping to an app store
needs a real signing certificate and provisioning profile.

### Emulator behaviour

On a HarmonyOS emulator there is no USB host service. `usbManager.getDevices()`
does not throw; it returns an empty list. The app starts normally, shows a
"USB is not available on this device" notice on the home screen, and stops at
the device list after an image is picked. That is expected, not a crash.

## Layout

```
harmonyos/
├── build.sh                     # build + sign helper
├── AppScope/                    # app-level config and resources
├── design/                      # upstream icon kept for provenance
└── entry/src/main/
    ├── module.json5             # permissions: KEEP_BACKGROUND_RUNNING only
    ├── resources/
    └── ets/
        ├── entryability/
        ├── pages/{Index,Confirm,Progress}.ets
        ├── service/             # write pipeline, background task, notifications
        ├── massstorage/         # SCSI bulk-only transport + block devices
        ├── utils/
        └── exceptions/
```

## How it maps to the Android app

| Android / Kotlin | HarmonyOS / ArkTS | Notes |
| --- | --- | --- |
| `libaums` | `massstorage/` | Hand-written SCSI BOT stack: `Scsi`, `BulkOnlyTransport` (CBW/CSW), `ScsiBlockDevice`, `BlockDevice{Input,Output}Stream` |
| `UsbManager` | `@ohos.usbManager` | Host mode: `getDevices`, `requestRight`, `bulkTransfer`, `usbControlTransfer` |
| Coroutines + `Channel` read-ahead | `utils/AsyncQueue.ets` | Bounded promise FIFO; the write side uses a promise chain with an in-flight limit |
| `WakeLock` | `backgroundTaskManager` DATA_TRANSFER task | Requested and released in `service/Notifications.ets` |
| `BroadcastReceiver` progress intents | `service/JobStore.ets` | In-process singleton holding the latest `JobStatus`, so re-entering the progress page shows live progress |
| `SharedPreferences` | `@ohos.data.preferences` | `AppSettings.ets` |
| `Intent` navigation | `router.replaceUrl` | |
| `NotificationCompat` progress notification | `@ohos.notificationManager` | Text notification with a `WantAgent` back into the app |
| Compose UI | ArkUI (declarative) | Same three screens and flow |
| `values/` + `values-zh-rCN/` string tables | `resources/base` + `resources/zh_CN` | Same wording as upstream's official Chinese translation; `%s` placeholders instead of `%1$s` |

## Differences from the Android app

- **UI is a fresh ArkUI implementation** of the same three screens and flow. It
  is not a pixel-for-pixel port of the Compose UI.
- **The launcher icon is the upstream one, unchanged** - the same artwork as
  `../app/src/main/res/mipmap-xxxhdpi/ic_launcher.png`. It is kept next to this
  port only because the HarmonyOS build needs it under `AppScope/` and
  `entry/src/main/resources/base/media/`.
- **No telemetry, no Sentry, no store-review prompts.** The upstream optional
  telemetry and in-app review code was not carried over, and no network
  permission is requested.
- **The progress page survives leaving and re-entering it**, because job state
  lives in an in-process singleton rather than a broadcast.
- **DMG images are not supported**, matching upstream's stated scope.

## Permissions and privacy

The module requests exactly one permission:

- `ohos.permission.KEEP_BACKGROUND_RUNNING` - a DATA_TRANSFER continuous task so
  a multi-minute write is not interrupted.

There is no `INTERNET` permission, no analytics, no advertising SDK, and no
personal data collection of any kind. The app only reads the image file the user
picks and writes to the USB device the user selects.

## Maintenance

Maintained by [@your-github-username](https://github.com/your-github-username).

This port deliberately leaves the Android build untouched: `settings.gradle.kts`
still includes only `:app`, no Gradle file is modified, and the CI workflows do
not build this directory.

If the EtchDroid maintainers would rather not carry a second toolchain in this
repository, this directory can be moved out to a standalone repository and
replaced with a one-line link in the top-level `README.md`.

## License and attribution

GPLv3, the same license as the rest of this repository (see
[`../LICENSE`](../LICENSE)).

This is a derived work of EtchDroid's Android implementation in
[`../app`](../app), which is Copyright (C) the EtchDroid authors (depau) and
contributors. This port is Copyright (C) its author. See [`NOTICE`](NOTICE) for
the provenance of the ported design.

This port is **not** affiliated with, nor endorsed by, the upstream EtchDroid
maintainers unless and until it is merged into this repository.
