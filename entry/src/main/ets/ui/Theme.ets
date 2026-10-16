/*
 * Colour scheme for the ported screens.
 *
 * Upstream uses Compose's MaterialTheme, which follows the system dark mode and
 * can be overridden by the Settings screen. ArkUI's own theming follows the system
 * mode too, but this app needs an explicit override, so the palette is computed
 * from the stored ThemeMode plus the system colour mode reported at startup.
 */

import { ThemeMode } from '../AppSettings';

/** AppStorage key holding the system-wide dark-mode state. */
export const SYSTEM_DARK_MODE_KEY = 'etchdroidSystemDarkMode';

/** Records the platform colour mode; called from EntryAbility. */
export function setSystemDarkMode(dark: boolean): void {
  AppStorage.setOrCreate<boolean>(SYSTEM_DARK_MODE_KEY, dark);
}

/** The effective dark state for a theme mode. */
export function isDarkMode(mode: ThemeMode): boolean {
  if (mode === ThemeMode.DARK) {
    return true;
  }
  if (mode === ThemeMode.LIGHT) {
    return false;
  }
  const stored: boolean | undefined = AppStorage.get<boolean>(SYSTEM_DARK_MODE_KEY);
  return stored === true;
}

/** Material 3-ish colours for light and dark mode. */
export class Palette {
  readonly dark: boolean;

  constructor(mode: ThemeMode) {
    this.dark = isDarkMode(mode);
  }

  get background(): string {
    return this.dark ? '#101014' : '#FFFBFE';
  }

  get surface(): string {
    return this.dark ? '#1C1B1F' : '#FFFFFF';
  }

  get surfaceVariant(): string {
    return this.dark ? '#2A2A2E' : '#F4EFF4';
  }

  get text(): string {
    return this.dark ? '#E6E1E5' : '#1C1B1F';
  }

  get textSecondary(): string {
    return this.dark ? '#A9A5AE' : '#49454F';
  }

  get primary(): string {
    return this.dark ? '#D0BCFF' : '#6650A4';
  }

  get onPrimary(): string {
    return this.dark ? '#381E72' : '#FFFFFF';
  }

  get outline(): string {
    return this.dark ? '#49454F' : '#CAC4D0';
  }

  get danger(): string {
    return this.dark ? '#FFB4AB' : '#B3261E';
  }

  get warning(): string {
    return this.dark ? '#FFD8A0' : '#7A5900';
  }

  get success(): string {
    return this.dark ? '#B7F0B1' : '#2E7D32';
  }
}
