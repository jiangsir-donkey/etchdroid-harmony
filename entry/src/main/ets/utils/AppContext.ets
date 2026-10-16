/*
 * Shared access to the UIAbilityContext.
 *
 * Pages need it for the document picker and for switching the system colour mode,
 * and ArkTS's `getContext(this)` is deprecated in favour of the UI context. Keeping
 * it in AppStorage gives every page the same reference the ability was created with.
 */

import { common } from '@kit.AbilityKit';

const KEY = 'etchdroidAbilityContext';

export function setAbilityContext(context: common.UIAbilityContext): void {
  AppStorage.setOrCreate<common.UIAbilityContext>(KEY, context);
}

export function abilityContext(): common.UIAbilityContext | undefined {
  return AppStorage.get<common.UIAbilityContext>(KEY);
}
