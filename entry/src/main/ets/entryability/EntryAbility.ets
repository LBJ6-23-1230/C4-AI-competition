import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { ApiEnvironmentStore } from '../api/ApiEnvironmentStore';
import { FixtureDemoStateStore } from '../api/FixtureDemoStateStore';
import { WorkflowSessionStore } from '../cache/WorkflowSessionStore';
import { ProactiveSurfaceService } from '../services/ProactiveSurfaceService';
import { ProactiveSettingsStore } from '../services/ProactiveSettingsStore';
import { AuthStore } from '../api/AuthStore';
import { appState } from '../data/AppState';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    if (!ApiEnvironmentStore.restore(this.context)) {
      hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Failed to restore API environment, using defaults.');
    }
    if (!FixtureDemoStateStore.initialize(this.context)) {
      hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Failed to restore fixture demo state.');
    }
    if (!WorkflowSessionStore.restore(this.context)) {
      hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Failed to restore workflow session.');
    }
    ProactiveSettingsStore.restore(this.context);
    const session = AuthStore.restore(this.context);
    if (session !== null) appState.applyIdentity(session);

    windowStage.loadContent(session === null ? 'pages/Login' : 'pages/ChatMain', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    ProactiveSurfaceService.refresh(this.context, true);
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    ProactiveSurfaceService.refresh(this.context, false);
  }

}
