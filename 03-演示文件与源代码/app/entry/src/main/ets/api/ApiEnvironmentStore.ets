import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AgentApiClient, ApiClientConfig } from './AgentApiClient';

/** Persists the developer-selected API environment across app restarts. */
export class ApiEnvironmentStore {
  private static readonly STORE_NAME: string = 'api_environment';
  private static readonly KEY_BASE_URL: string = 'base_url';
  private static readonly KEY_USE_FIXTURE: string = 'use_fixture';
  private static readonly KEY_TIMEOUT_MS: string = 'timeout_ms';

  static restore(context: common.UIAbilityContext): boolean {
    try {
      const defaults: ApiClientConfig = AgentApiClient.getConfig();
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: ApiEnvironmentStore.STORE_NAME
      });
      AgentApiClient.configure({
        baseUrl: store.getSync(ApiEnvironmentStore.KEY_BASE_URL, defaults.baseUrl) as string,
        useFixture: store.getSync(ApiEnvironmentStore.KEY_USE_FIXTURE, defaults.useFixture) as boolean,
        timeoutMs: store.getSync(ApiEnvironmentStore.KEY_TIMEOUT_MS, defaults.timeoutMs) as number
      });
      return true;
    } catch (error) {
      return false;
    }
  }

  static save(context: common.UIAbilityContext, config: ApiClientConfig): boolean {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: ApiEnvironmentStore.STORE_NAME
      });
      store.putSync(ApiEnvironmentStore.KEY_BASE_URL, config.baseUrl);
      store.putSync(ApiEnvironmentStore.KEY_USE_FIXTURE, config.useFixture);
      store.putSync(ApiEnvironmentStore.KEY_TIMEOUT_MS, config.timeoutMs);
      store.flushSync();
      return true;
    } catch (error) {
      return false;
    }
  }
}
