import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AuthSession } from './AuthModels';

/** Stores only the local demo identity. It is not server authentication. */
export class AuthStore {
  private static readonly STORE_NAME: string = 'local_identity';
  private static readonly KEY_USER_ID: string = 'user_id';
  private static readonly KEY_NICKNAME: string = 'nickname';
  private static readonly KEY_SOURCE: string = 'source';

  static restore(context: common.UIAbilityContext): AuthSession | null {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: AuthStore.STORE_NAME });
      const userId: string = store.getSync(AuthStore.KEY_USER_ID, '') as string;
      const nickname: string = store.getSync(AuthStore.KEY_NICKNAME, '') as string;
      const source: string = store.getSync(AuthStore.KEY_SOURCE, '') as string;
      if (userId.length === 0 || nickname.length === 0 || (source !== 'guest' && source !== 'local')) return null;
      return { userId: userId, nickname: nickname, source: source === 'local' ? 'local' : 'guest' };
    } catch (error) {
      return null;
    }
  }

  static save(context: common.UIAbilityContext, session: AuthSession): boolean {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: AuthStore.STORE_NAME });
      store.putSync(AuthStore.KEY_USER_ID, session.userId);
      store.putSync(AuthStore.KEY_NICKNAME, session.nickname);
      store.putSync(AuthStore.KEY_SOURCE, session.source);
      store.flushSync();
      return true;
    } catch (error) {
      return false;
    }
  }

  static clear(context: common.UIAbilityContext): boolean {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: AuthStore.STORE_NAME });
      store.clearSync();
      store.flushSync();
      return true;
    } catch (error) {
      return false;
    }
  }
}
