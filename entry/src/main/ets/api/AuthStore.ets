import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { ApiDefaults } from './ApiDefaults';
import { AuthProvider, AuthUser, StoredSession } from './AuthModels';

/**
 * 登录态持久化（照 `ApiEnvironmentStore` / `FixtureDemoStateStore` 的既有范式实现）。
 *
 * 只做一件事：把 `StoredSession` 存进 preferences，下次启动时恢复。
 * **不做任何网络请求**——校验 token 是否仍然有效由 `AuthClient.restore()` 负责，
 * 且校验失败必须降级为游客身份而不是卡在登录页（见 `restore()` 注释）。
 */
export class AuthStore {
  private static readonly STORE_NAME: string = 'auth_session';
  private static readonly KEY_USER_ID: string = 'user_id';
  private static readonly KEY_TOKEN: string = 'token';
  private static readonly KEY_EXPIRES_AT: string = 'expires_at';
  private static readonly KEY_NICKNAME: string = 'nickname';
  private static readonly KEY_GRADE: string = 'grade';
  private static readonly KEY_PROVIDER: string = 'auth_provider';
  private static readonly KEY_SAVED_AT: string = 'saved_at';

  private static context: common.UIAbilityContext | null = null;
  private static session: StoredSession | null = null;

  static initialize(context: common.UIAbilityContext): boolean {
    AuthStore.context = context;
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: AuthStore.STORE_NAME
      });
      const userId: string = store.getSync(AuthStore.KEY_USER_ID, '') as string;
      const token: string = store.getSync(AuthStore.KEY_TOKEN, '') as string;
      if (userId.length === 0 || token.length === 0) {
        AuthStore.session = null;
        return true;
      }
      AuthStore.session = {
        userId: userId,
        token: token,
        expiresAt: store.getSync(AuthStore.KEY_EXPIRES_AT, '') as string,
        nickname: store.getSync(AuthStore.KEY_NICKNAME, '') as string,
        grade: store.getSync(AuthStore.KEY_GRADE, '') as string,
        authProvider: store.getSync(AuthStore.KEY_PROVIDER, 'local') as AuthProvider,
        savedAt: store.getSync(AuthStore.KEY_SAVED_AT, '') as string
      };
      return true;
    } catch (error) {
      AuthStore.session = null;
      return false;
    }
  }

  /** 当前设备保存的登录态；null 表示处于游客 / 演示身份。 */
  static getSession(): StoredSession | null {
    return AuthStore.session;
  }

  static getToken(): string {
    return AuthStore.session === null ? '' : AuthStore.session.token;
  }

  static getUserId(): string {
    return AuthStore.session === null ? ApiDefaults.DEMO_USER_ID : AuthStore.session.userId;
  }

  /** 是否处于真实登录态（游客身份返回 false）。 */
  static isSignedIn(): boolean {
    return AuthStore.session !== null;
  }

  static save(user: AuthUser, token: string, expiresAt: string): boolean {
    const session: StoredSession = {
      userId: user.userId,
      token: token,
      expiresAt: expiresAt,
      nickname: user.nickname,
      grade: user.grade,
      authProvider: user.authProvider,
      savedAt: new Date().toISOString()
    };
    AuthStore.session = session;
    return AuthStore.persist();
  }

  static clear(): boolean {
    AuthStore.session = null;
    return AuthStore.persist();
  }

  private static persist(): boolean {
    const context: common.UIAbilityContext | null = AuthStore.context;
    if (context === null) {
      // 尚未 initialize（例如单元测试 / 极早期调用）：内存态已生效即可
      return true;
    }
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: AuthStore.STORE_NAME
      });
      const session: StoredSession | null = AuthStore.session;
      if (session === null) {
        store.deleteSync(AuthStore.KEY_USER_ID);
        store.deleteSync(AuthStore.KEY_TOKEN);
        store.deleteSync(AuthStore.KEY_EXPIRES_AT);
        store.deleteSync(AuthStore.KEY_NICKNAME);
        store.deleteSync(AuthStore.KEY_GRADE);
        store.deleteSync(AuthStore.KEY_PROVIDER);
        store.deleteSync(AuthStore.KEY_SAVED_AT);
      } else {
        store.putSync(AuthStore.KEY_USER_ID, session.userId);
        store.putSync(AuthStore.KEY_TOKEN, session.token);
        store.putSync(AuthStore.KEY_EXPIRES_AT, session.expiresAt);
        store.putSync(AuthStore.KEY_NICKNAME, session.nickname);
        store.putSync(AuthStore.KEY_GRADE, session.grade);
        store.putSync(AuthStore.KEY_PROVIDER, session.authProvider);
        store.putSync(AuthStore.KEY_SAVED_AT, session.savedAt);
      }
      store.flushSync();
      return true;
    } catch (error) {
      return false;
    }
  }
}
