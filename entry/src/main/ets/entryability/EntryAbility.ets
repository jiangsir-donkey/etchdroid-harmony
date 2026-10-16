import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { Configuration, ConfigurationConstant, common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppSettings } from '../AppSettings';
import { JobStore } from '../service/JobStore';
import { setAbilityContext } from '../utils/AppContext';
import { setResourceContext } from '../utils/Resources';
import { setSystemDarkMode } from '../ui/Theme';
import { resourceManager } from '@kit.LocalizationKit';

const DOMAIN: number = 0xE7C4;
const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');

    // Everything the ported code needs a Context for is resolved once, here:
    // localized strings, the stored settings, and the notification/continuous-task
    // controller the job uses.
    setAbilityContext(this.context);
    setResourceContext(this.context);
    AppSettings.get().init(this.context);
    JobStore.get().attach(this.context);
    this.refreshColorMode();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    setSystemDarkMode(newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
  }

  /** Seeds the theme with the platform colour mode so SYSTEM is correct on launch. */
  private refreshColorMode(): void {
    try {
      const config = this.context.resourceManager.getConfigurationSync();
      setSystemDarkMode(config.colorMode === resourceManager.ColorMode.DARK);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'Could not read the platform colour mode: %{public}s', JSON.stringify(error));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }
}
