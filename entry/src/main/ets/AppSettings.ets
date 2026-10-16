/*
 * Port of eu.depau.etchdroid.AppSettings.
 *
 * Upstream stores these four values in SharedPreferences and pushes changes to
 * registered listeners; ArkTS's equivalent is the preferences store plus an
 * in-process listener list. Values are cached so readers never have to await.
 */

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { Logger } from './utils/Logger';
import { errorText } from './utils/ErrorText';

const LOG = new Logger('AppSettings');
const STORE_NAME = 'settings';

const KEY_THEME_MODE = 'theme_mode';
const KEY_DYNAMIC_COLORS = 'dynamic_colors';
const KEY_NOTIFICATIONS_BANNER = 'show_notifications_banner';
const KEY_TELEMETRY_BANNER = 'show_telemetry_banner';

/** Same three options upstream offers. */
export enum ThemeMode {
  SYSTEM = 'SYSTEM',
  LIGHT = 'LIGHT',
  DARK = 'DARK',
}

/** Notified whenever any setting changes. */
export interface SettingsChangeListener {
  onSettingsChanged(settings: AppSettings): void;
}

function parseThemeMode(value: string): ThemeMode {
  if (value === ThemeMode.LIGHT) {
    return ThemeMode.LIGHT;
  }
  if (value === ThemeMode.DARK) {
    return ThemeMode.DARK;
  }
  return ThemeMode.SYSTEM;
}

export class AppSettings {
  private static instance: AppSettings | null = null;

  private store: preferences.Preferences | null = null;
  private listeners: SettingsChangeListener[] = [];

  private themeModeValue: ThemeMode = ThemeMode.SYSTEM;
  private dynamicColorsValue: boolean = false;
  private showNotificationsBannerValue: boolean = true;
  private showTelemetryBannerValue: boolean = true;

  static get(): AppSettings {
    if (AppSettings.instance === null) {
      AppSettings.instance = new AppSettings();
    }
    return AppSettings.instance;
  }

  /** Loads persisted values. Call once at startup, before any page reads them. */
  init(context: common.Context): void {
    if (this.store !== null) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(context, { name: STORE_NAME });
      this.store = store;
      this.themeModeValue = parseThemeMode(store.getSync(KEY_THEME_MODE, ThemeMode.SYSTEM) as string);
      this.dynamicColorsValue = store.getSync(KEY_DYNAMIC_COLORS, false) as boolean;
      this.showNotificationsBannerValue = store.getSync(KEY_NOTIFICATIONS_BANNER, true) as boolean;
      this.showTelemetryBannerValue = store.getSync(KEY_TELEMETRY_BANNER, true) as boolean;
    } catch (error) {
      // A broken store must not stop the app: fall back to the defaults above.
      LOG.warn(`Failed to load settings: ${errorText(error)}`);
    }
  }

  addListener(listener: SettingsChangeListener): void {
    this.listeners.push(listener);
  }

  private notifyListeners(): void {
    for (const listener of this.listeners) {
      listener.onSettingsChanged(this);
    }
  }

  private put(key: string, value: preferences.ValueType): void {
    const store = this.store;
    if (store === null) {
      return;
    }
    try {
      store.putSync(key, value);
      store.flush();
    } catch (error) {
      LOG.warn(`Failed to persist ${key}: ${errorText(error)}`);
    }
  }

  get themeMode(): ThemeMode {
    return this.themeModeValue;
  }

  set themeMode(value: ThemeMode) {
    this.themeModeValue = value;
    this.put(KEY_THEME_MODE, value);
    this.notifyListeners();
  }

  get dynamicColors(): boolean {
    return this.dynamicColorsValue;
  }

  set dynamicColors(value: boolean) {
    this.dynamicColorsValue = value;
    this.put(KEY_DYNAMIC_COLORS, value);
    this.notifyListeners();
  }

  get showNotificationsBanner(): boolean {
    return this.showNotificationsBannerValue;
  }

  set showNotificationsBanner(value: boolean) {
    this.showNotificationsBannerValue = value;
    this.put(KEY_NOTIFICATIONS_BANNER, value);
    this.notifyListeners();
  }

  get showTelemetryBanner(): boolean {
    return this.showTelemetryBannerValue;
  }

  set showTelemetryBanner(value: boolean) {
    this.showTelemetryBannerValue = value;
    this.put(KEY_TELEMETRY_BANNER, value);
    this.notifyListeners();
  }
}
