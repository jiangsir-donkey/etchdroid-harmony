/*
 * Resource lookup by name.
 *
 * EtchDroid's exceptions carry the resource key for their user-facing message
 * rather than a resolved string, so the UI can localize them late. ArkTS resolves
 * resources through the Context's ResourceManager, so the application context is
 * captured once at startup and reused here.
 */

import { common } from '@kit.AbilityKit';
import { EtchDroidException } from '../exceptions/Exceptions';

let resourceContext: common.Context | null = null;

/** Records the application context used by every later lookup. */
export function setResourceContext(context: common.Context): void {
  resourceContext = context;
}

/** Resolves a `string.json` entry by name, optionally formatting it. */
export function stringByName(name: string, params: (string | number)[] = []): string {
  const context = resourceContext;
  if (context === null) {
    return name;
  }
  try {
    const manager = context.resourceManager;
    if (params.length === 0) {
      return manager.getStringByNameSync(name);
    }
    if (params.length === 1) {
      return manager.getStringByNameSync(name, params[0]);
    }
    if (params.length === 2) {
      return manager.getStringByNameSync(name, params[0], params[1]);
    }
    return manager.getStringByNameSync(name, params[0], params[1], params[2]);
  } catch (error) {
    // Missing translations must never take the UI down.
    return name;
  }
}

/** Resolves the localized message an EtchDroidException wants to show. */
export function exceptionMessage(exception: EtchDroidException): string {
  return stringByName(exception.uiMessageRes, exception.uiMessageParams);
}
