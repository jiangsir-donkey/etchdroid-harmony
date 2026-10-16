/*
 * Port of eu.depau.etchdroid.utils.exception to ArkTS.
 *
 * Upstream models these as an IOException hierarchy with a getUiMessage(Context)
 * method. ArkTS has no Context-aware exception API, so every exception instead
 * carries the resource key (and format parameters) the UI needs to explain it.
 */

import { errorText } from '../utils/ErrorText';

/** Base class of every error EtchDroid reports to the user. */
export class EtchDroidException extends Error {
  /** `string.json` entry describing this failure to the user. */
  readonly uiMessageRes: string;
  /** Positional parameters for `uiMessageRes`, formatted with %s. */
  readonly uiMessageParams: string[];
  /** Underlying failure, if any. Mirrors upstream's Throwable.cause. */
  readonly innerCause: Error | undefined;

  constructor(message: string, uiMessageRes: string, uiMessageParams: string[] = [], innerCause?: Error) {
    super(message);
    this.name = 'EtchDroidException';
    this.uiMessageRes = uiMessageRes;
    this.uiMessageParams = uiMessageParams;
    this.innerCause = innerCause;
  }
}

/** An error the user cannot recover from without restarting the operation. */
export class FatalException extends EtchDroidException {
  constructor(message: string, uiMessageRes: string, uiMessageParams: string[] = [], innerCause?: Error) {
    super(message, uiMessageRes, uiMessageParams, innerCause);
    this.name = 'FatalException';
  }
}

/** An error that may be recovered by reconnecting the drive and retrying. */
export class RecoverableException extends EtchDroidException {
  /** True when the drive was physically disconnected mid-transfer. */
  readonly isUnplugged: boolean;

  constructor(
    message: string,
    uiMessageRes: string,
    uiMessageParams: string[] = [],
    innerCause?: Error,
    isUnplugged: boolean = false,
  ) {
    super(message, uiMessageRes, uiMessageParams, innerCause);
    this.name = 'RecoverableException';
    this.isUnplugged = isUnplugged;
  }
}

/** Maximum depth walked by rootCause(); guards against a malformed cause cycle. */
const MAX_CAUSE_DEPTH = 64;

/** The most deeply nested cause in the chain. */
export function rootCause(error: Error): Error {
  let current: Error = error;
  for (let depth = 0; depth < MAX_CAUSE_DEPTH; depth++) {
    if (!(current instanceof EtchDroidException)) {
      return current;
    }
    const next: Error | undefined = (current as EtchDroidException).innerCause;
    if (next === undefined) {
      return current;
    }
    current = next;
  }
  return current;
}

/**
 * Normalizes an arbitrary thrown value into an Error.
 *
 * The result is guaranteed to carry a real string message: a native BusinessError
 * passes `instanceof Error` on some builds but its `message` may be a non-string
 * native value, and interpolating that later would abort the UI. Only values whose
 * message really is a string are passed through untouched.
 */
export function toError(value: Object): Error {
  if (value instanceof Error) {
    const message: Object | undefined = (value as Error).message;
    if (typeof message === 'string') {
      return value;
    }
  }
  return new Error(errorText(value));
}

export function isUnplugged(error: Error): boolean {
  if (error instanceof RecoverableException) {
    return error.isUnplugged;
  }
  return false;
}

/** Normalizes an arbitrary thrown value into an EtchDroidException. */
export function toEtchDroidException(value: Object): EtchDroidException {
  if (value instanceof EtchDroidException) {
    return value;
  }
  return new UnknownException(toError(value));
}

// ---------------------------------------------------------------------------
// Recoverable failures
// ---------------------------------------------------------------------------

export class MissingPermissionException extends RecoverableException {
  constructor() {
    super('Missing permission to access USB device', 'missing_permission_to_access_the_usb_device');
    this.name = 'MissingPermissionException';
  }
}

export class InitException extends RecoverableException {
  constructor(message: string, cause?: Error) {
    super(message, 'the_device_is_not_responding', [], cause);
    this.name = 'InitException';
  }
}

export class UsbCommunicationException extends RecoverableException {
  constructor(cause?: Error, noDevice: boolean = false) {
    super('Communication failed', 'the_usb_drive_stopped_responding', [], cause, noDevice);
    this.name = 'UsbCommunicationException';
  }
}

/**
 * The USB transfer stalled long enough for the I/O watchdog to fire. Distinct from
 * UsbCommunicationException so it groups separately in telemetry, but shares its
 * recoverable behaviour and UI message.
 */
export class UsbCommunicationTimeoutException extends UsbCommunicationException {
  constructor(cause?: Error) {
    super(cause);
    this.name = 'UsbCommunicationTimeoutException';
  }
}

// ---------------------------------------------------------------------------
// Fatal failures
// ---------------------------------------------------------------------------

export class MissingDeviceException extends FatalException {
  constructor() {
    super('Worker service launched with null device', 'no_destination_device_selected');
    this.name = 'MissingDeviceException';
  }
}

export class OpenFileException extends FatalException {
  constructor(message: string, cause?: Error) {
    super(message, 'could_not_open_the_source_file', [], cause);
    this.name = 'OpenFileException';
  }
}

export class NotEnoughSpaceException extends FatalException {
  readonly sourceSize: number;
  readonly destSize: number;

  constructor(sourceSize: number, destSize: number, sourceText: string, destText: string) {
    super(
      `Image size (${sourceSize}) is larger than device size (${destSize})`,
      'the_image_is_is_larger_than_the_device',
      [sourceText, destText],
    );
    this.name = 'NotEnoughSpaceException';
    this.sourceSize = sourceSize;
    this.destSize = destSize;
  }
}

export class UsbDriveTooLargeException extends FatalException {
  constructor() {
    super('The USB drive is too large and EtchDroid does not support it', 'the_usb_drive_is_too_large');
    this.name = 'UsbDriveTooLargeException';
  }
}

export class VerificationFailedException extends FatalException {
  constructor() {
    super('Verification failed', 'the_usb_device_content_does_not_match_the_image');
    this.name = 'VerificationFailedException';
  }
}

export class ServiceTimeoutException extends FatalException {
  constructor() {
    super('Timed out while waiting for service to start', 'service_timeout_message');
    this.name = 'ServiceTimeoutException';
  }
}

export class UnknownException extends FatalException {
  constructor(cause: Error) {
    super('Unknown error', 'an_unknown_error_occurred', [errorText(cause)], cause);
    this.name = 'UnknownException';
  }
}
