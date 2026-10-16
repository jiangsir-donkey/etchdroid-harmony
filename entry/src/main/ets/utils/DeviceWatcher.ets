/*
 * Keeps the visible list of mass-storage devices up to date.
 *
 * Upstream registers a BroadcastReceiver for ACTION_USB_DEVICE_ATTACHED and
 * ACTION_USB_DEVICE_DETACHED. HarmonyOS exposes the same information only through
 * the (system-scoped) commonEventManager USB events, which third-party apps are not
 * guaranteed to receive, so the device list is polled instead. Polling also covers
 * the case upstream has to work around with a settle delay: a drive that wedges
 * without disconnecting never emits an attach event at all.
 *
 * The watcher also reports whether the USB host service itself could be reached.
 * A device with no USB passthrough (an emulator, for instance) answers neither yes
 * nor no, and the start screen has to say so rather than wait for a drive that can
 * never appear.
 */

import { Logger } from './Logger';
import { errorText } from './ErrorText';
import { DeviceInfo, MassStorageScan, scanMassStorageDevices } from '../massstorage/UsbMassStorageDevice';

const LOG = new Logger('DeviceWatcher');

/** Receives the current device list whenever it changes, and USB availability. */
export type DeviceListListener = (devices: DeviceInfo[], usbAvailable: boolean) => void;

const DEFAULT_INTERVAL_MS = 1500;

export class DeviceWatcher {
  private timer: number = -1;
  private listener: DeviceListListener | null = null;
  private lastKey: string = '';

  /** Starts polling; `listener` is called immediately and then only on changes. */
  start(listener: DeviceListListener, intervalMs: number = DEFAULT_INTERVAL_MS): void {
    this.stop();
    this.listener = listener;
    this.lastKey = '';
    this.poll();
    this.timer = setInterval((): void => {
      this.poll();
    }, intervalMs);
  }

  stop(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    this.listener = null;
    this.lastKey = '';
  }

  /** Forces an immediate refresh; used right after a permission prompt. */
  refresh(): void {
    this.poll();
  }

  /**
   * Never throws: it runs from a timer and from aboutToAppear, and an escaping
   * error there would take the whole page down with it.
   */
  private poll(): void {
    const listener = this.listener;
    if (listener === null) {
      return;
    }

    let scan: MassStorageScan;
    try {
      scan = scanMassStorageDevices();
    } catch (error) {
      LOG.warn(`USB scan failed: ${errorText(error)}`);
      scan = new MassStorageScan();
      scan.usbAvailable = false;
    }

    const devices: DeviceInfo[] = [];
    const seen: string[] = [];
    for (const descriptor of scan.devices) {
      if (seen.indexOf(descriptor.deviceName) >= 0) {
        continue;
      }
      seen.push(descriptor.deviceName);
      devices.push(descriptor.toDeviceInfo());
    }

    let key = scan.usbAvailable ? 'usb;' : 'nousb;';
    for (const device of devices) {
      key += `${device.deviceName}|${device.vidpid};`;
    }
    if (key === this.lastKey) {
      return;
    }
    this.lastKey = key;

    // Reported only when the state changes: the poll runs every 1.5 s and a device
    // without USB passthrough answers the same way every single time.
    if (scan.failure.length > 0) {
      if (scan.usbAvailable) {
        LOG.warn(`A USB device could not be described: ${scan.failure}`);
      } else {
        LOG.warn(`The USB host service is unreachable: ${scan.failure}`);
      }
    }
    listener(devices, scan.usbAvailable);
  }
}
