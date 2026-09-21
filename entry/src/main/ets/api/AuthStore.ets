import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { ApiDefaults } from './ApiDefaults';
import { AuthProvider, AuthUser, StoredSession } from './AuthModels';
import { TokenCipher } from './TokenCipher';

/**
 * 登录态持久化（照 `ApiEnvironmentStore` / `FixtureDemoStateStore` 的既有范式实现）。
 *
 * 只做一件事：把 `StoredSession` 存进 preferences，下次启动时恢复。
 * **不做任何网络请求**——校验 token 是否仍然有效由 `AuthClient.restore()` 负责，
 * 且校验失败必须降级为游客身份而不是卡在登录页（见 `restore()` 注释）。
 *
 * token 的存储方式（本轮变更）
 * ---------------------------
 * 原先 token **明文**写进 preferences。preferences 位于应用私有目录，
 * 但它不是安全存储：备份、调试桥、任何拿到沙箱的途径都能读出明文，
 * 而 token 等同于账号（有效期 30 天）。
 *
 * 现在 token 经 `TokenCipher`（AES-256-GCM，每条消息独立 nonce）加密后再落盘，
 * 数据密钥托管在系统**资产库**（Asset Store Kit）而非 preferences。
 *
 * ⚠️ **仍然存在的边界（如实记录，不夸大）**：
 *   · 密钥是**软件密钥**，不是 HUKS 硬件密钥（HUKS 需要多轮异步交互，
 *     与本类的同步 preferences 范式不兼容）。
 *   · 加密不可用时会**降级为明文**，同时把 `AuthStore.encryptionDegraded()`
 *     置为 true，由账号页如实提示用户 —— 不静默假装安全。
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
  /** 本次运行是否处于"加密不可用 → 明文降级"状态。 */
  private static degraded: boolean = false;

  /**
   * 初始化并**尝试**启用 token 加密。
   *
   * 设计成异步：`EntryAbility` 可以 `await` 它，也可以不 await
   * （不 await 时先按内存态工作，加密就绪后下一次 `save()` 自动改用密文）。
   */
  static async initialize(context: common.UIAbilityContext): Promise<boolean> {
    AuthStore.context = context;
    // 加密不可用不应阻断启动：失败只是降级为明文，并标记 degraded
    try {
      await TokenCipher.initialize();
    } catch (error) {
      // TokenCipher.initialize 内部已兜异常，这里是双保险
    }
    AuthStore.degraded = !TokenCipher.isReady();
    return AuthStore.loadFromPreferences(context);
  }

  /** 把 preferences 里的内容读进内存（含密文解密）。 */
  private static loadFromPreferences(context: common.UIAbilityContext): boolean {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: AuthStore.STORE_NAME
      });
      const userId: string = store.getSync(AuthStore.KEY_USER_ID, '') as string;
      const storedToken: string = store.getSync(AuthStore.KEY_TOKEN, '') as string;
      if (userId.length === 0 || storedToken.length === 0) {
        AuthStore.session = null;
        return true;
      }
      const token: string = AuthStore.decodeToken(storedToken);
      if (token.length === 0) {
        // 密文解不开（换过密钥 / 被篡改）→ 视为无有效凭据，清掉并让用户重新登录
        AuthStore.session = null;
        AuthStore.persist();
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

  /** 同步初始化（兼容既有调用点）。加密此时**尚未**就绪，会标记为降级。 */
  static initializeSync(context: common.UIAbilityContext): boolean {
    AuthStore.context = context;
    AuthStore.degraded = !TokenCipher.isReady();
    return AuthStore.loadFromPreferences(context);
  }

  /**
   * token 是否处于明文降级状态。
   *
   * 账号页应当据此提示用户（`true` 表示设备加密不可用、凭据以明文保存）。
   */
  static encryptionDegraded(): boolean {
    return AuthStore.degraded;
  }

  /** 把落盘的 token 还原成明文；识别不出密文格式时按"本就是旧的明文"处理。 */
  private static decodeToken(stored: string): string {
    if (TokenCipher.isReady() && TokenCipher.looksEncrypted(stored)) {
      const plain: string | null = TokenCipher.decrypt(stored);
      return plain !== null ? plain : '';
    }
    // 加密未就绪，或存量数据是升级前写入的明文 —— 原样返回，保证老用户不掉线
    return stored;
  }

  /** 把明文 token 编码成待落盘的形式（加密可用则密文，否则明文 + 降级标记）。 */
  private static encodeToken(plain: string): string {
    if (!TokenCipher.isReady()) {
      AuthStore.degraded = true;
      return plain;
    }
    const encoded: string | null = TokenCipher.encrypt(plain);
    if (encoded === null) {
      // 加密失败：降级为明文，但**如实标记**，不假装已加密
      AuthStore.degraded = true;
      return plain;
    }
    AuthStore.degraded = false;
    return encoded;
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
        // token 加密后落盘（见类注释）。`encodeToken` 失败时会降级为明文并置 degraded。
        store.putSync(AuthStore.KEY_TOKEN, AuthStore.encodeToken(session.token));
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
