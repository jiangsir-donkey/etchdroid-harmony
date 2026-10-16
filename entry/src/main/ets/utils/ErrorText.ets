/*
 * Safe text for a thrown value.
 *
 * ArkTS refuses to convert some values to text: the BusinessError the USB service
 * throws is a native object with no JavaScript toString(), so `String(error)` or
 * `${error}` aborts with "Cannot convert a illegal value to a String". That
 * TypeError is raised *while handling* the original failure, so it escapes the
 * catch block that produced it and takes the whole ability down - a missing USB
 * service made the start screen crash instead of showing "no drive attached".
 *
 * Only primitive, explicitly type-checked fields are read here. The object itself
 * is never interpolated, and calls that log errors go through this helper.
 */

import { BusinessError } from '@kit.BasicServicesKit';

/** Human-readable text for any thrown value, safe for native error objects. */
export function errorText(error: Object | null | undefined): string {
  if (error === null || error === undefined) {
    return 'unknown error';
  }

  let detail: string = '';
  const message: Object | undefined = (error as BusinessError).message;
  if (typeof message === 'string') {
    detail = message;
  }

  // Our own exceptions are real Errors and already say something useful.
  if (error instanceof Error && detail.length > 0) {
    return detail;
  }

  const code: Object | undefined = (error as BusinessError).code;
  const name: Object | undefined = (error as Error).name;

  // A numeric/string code from the platform is more informative than the class
  // name, so it wins when both are present.
  let head: string = '';
  if (typeof code === 'number') {
    head = `code ${code}`;
  } else if (typeof code === 'string' && code.length > 0) {
    head = `code ${code}`;
  } else if (typeof name === 'string' && name.length > 0) {
    head = name;
  }

  if (head.length === 0) {
    return detail.length > 0 ? detail : 'unknown error';
  }
  return detail.length > 0 ? `${head}: ${detail}` : head;
}
