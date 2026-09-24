import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** User-controlled switch for proactive system notifications. */
export class ProactiveSettingsStore {
  private static readonly STORE_NAME: string = 'proactive_settings';
  private static readonly KEY_NOTIFICATION_ENABLED: string = 'notification_enabled';
  private static enabled: boolean = false;

  static restore(context: common.UIAbilityContext): boolean {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: ProactiveSettingsStore.STORE_NAME });
      ProactiveSettingsStore.enabled = store.getSync(ProactiveSettingsStore.KEY_NOTIFICATION_ENABLED, false) as boolean;
      return true;
    } catch (error) {
      ProactiveSettingsStore.enabled = false;
      return false;
    }
  }

  static isEnabled(): boolean {
    return ProactiveSettingsStore.enabled;
  }

  static save(context: common.UIAbilityContext, enabled: boolean): boolean {
    ProactiveSettingsStore.enabled = enabled;
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: ProactiveSettingsStore.STORE_NAME });
      store.putSync(ProactiveSettingsStore.KEY_NOTIFICATION_ENABLED, enabled);
      store.flushSync();
      return true;
    } catch (error) {
      return false;
    }
  }
}
