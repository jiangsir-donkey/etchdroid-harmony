/*
 * Port of eu.depau.etchdroid.utils.ktexts.NumberToSizeString and
 * NumberToTimeString. Both use 1000-based (SI) units, as upstream does.
 */

const SI_UNIT = 1000;
const PREFIXES = 'KMGTPE';

/**
 * Formats a byte count the same way upstream's humanReadableByteCount does:
 * one decimal place, switching to the next SI prefix each time the value exceeds
 * the unit.
 */
export function toHrSize(bytes: number, si: boolean = true): string {
  const unit: number = si ? SI_UNIT : 1024;
  if (bytes < unit) {
    return `${bytes.toFixed(1)} B`;
  }
  const exponent = Math.floor(Math.log(bytes) / Math.log(unit));
  const prefix = PREFIXES.charAt(Math.min(exponent - 1, PREFIXES.length - 1)) + (si ? '' : 'i');
  const scaled = bytes / Math.pow(unit, exponent);
  return `${scaled.toFixed(1)} ${prefix}B`;
}

const TIME_SUFFIXES: string[] = ['s', 'm', 'h', 'd'];
const TIME_DIVISORS: number[] = [60, 60, 24];

/** Formats a duration in milliseconds as "1h 2m 3s", matching upstream. */
export function toHrTime(millis: number): string {
  let value = millis / 1000.0;
  let out = '';

  for (let i = 0; i < TIME_DIVISORS.length; i++) {
    const divisor = TIME_DIVISORS[i];
    const suffix = TIME_SUFFIXES[i];
    out = `${Math.floor(value % divisor)}${suffix}${out}`;
    if (value < divisor) {
      return out;
    }
    out = ` ${out}`;
    value /= divisor;
  }

  return `${Math.floor(value)}${TIME_SUFFIXES[TIME_SUFFIXES.length - 1]} ${out}`;
}

/** Clamps a value into [min, max]. */
export function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}

/**
 * Extracts a human-readable file name from a picker URI.
 *
 * Upstream asks the ContentResolver for the document's display name; the picker's
 * URI ends with the same name, percent-encoded.
 */
export function fileNameFromUri(uri: string): string {
  let name = uri;
  const slash = name.lastIndexOf('/');
  if (slash >= 0) {
    name = name.substring(slash + 1);
  }
  try {
    return decodeURIComponent(name);
  } catch (error) {
    return name;
  }
}
