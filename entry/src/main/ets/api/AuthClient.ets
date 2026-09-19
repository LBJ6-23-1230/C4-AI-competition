import { ApiDefaults } from './ApiDefaults';
import { AgentApiClient } from './AgentApiClient';
import { ApiFailure, ApiResult } from './ApiResult';
import { AuthResult } from './AuthResult';
import { AuthStore } from './AuthStore';
import { AuthUser, NICKNAME_MAX_LENGTH, NICKNAME_MIN_LENGTH, StoredSession } from './AuthModels';

/**
 * 登录流程编排。
 *
 * 三条入口对应三个方法，**全部保证「一定能进 App」**——这是本设计的核心：
 *
 *   | 入口           | 方法                | userId        | token | 需要后端 |
 *   |----------------|---------------------|---------------|-------|---------|
 *   | 一键体验       | continueAsGuest()   | demo-user     | 无    | 否      |
 *   | 昵称开始       | register(nickname)  | 服务端下发     | 有    | 是      |
 *   | 已登录恢复     | restore()           | 本地保存       | 本地  | 是（可降级）|
 *
 * 任何网络失败都**不会把用户挡在登录页**：要么降级为游客身份，要么切离线 Fixture。
 * 演示时评委点不进去 = 灾难，这条纪律优先于一切。
 */
export class AuthClient {
  // ---------------------------------------------------------------- 一键体验
  /**
   * 游客 / 演示身份进入。不发任何网络请求，使用约定的 demo-user。
   * 演示主链（mastery 42 / Plan V1 [30,30] / √√√→66.67→58）完全不受影响。
   */
  static continueAsGuest(): AuthResult {
    AuthStore.clear();
    return { ok: true, user: AuthClient.guestUser(), source: 'guest', message: '' };
  }

  /** 离线 Fixture 模式：与游客身份一致，但明确标注数据来源为本地。 */
  static continueOffline(useFixture: boolean): AuthResult {
    AuthStore.clear();
    const message: string = useFixture
      ? '已进入离线演示模式，全部数据由本机 Fixture 提供，判分规则与后端一致。'
      : '';
    return { ok: true, user: AuthClient.guestUser(), source: 'fixture', message: message };
  }

  private static guestUser(): AuthUser {
    return {
      userId: ApiDefaults.DEMO_USER_ID,
      nickname: ApiDefaults.DEMO_USER_NAME,
      grade: '',
      authProvider: 'guest',
      createdAt: '',
      lastLoginAt: ''
    };
  }

  // ---------------------------------------------------------------- 注册
  /** 校验昵称，返回中文错误消息；通过则返回空串。与后端规则保持一致。 */
  static validateNickname(nickname: string): string {
    const trimmed: string = nickname.trim();
    if (trimmed.length < NICKNAME_MIN_LENGTH) {
      return '请先填写昵称。';
    }
    if (trimmed.length > NICKNAME_MAX_LENGTH) {
      return `昵称不能超过 ${NICKNAME_MAX_LENGTH} 个字符。`;
    }
    return '';
  }

  /**
   * 注册并登录。失败时**不改变**当前登录态，由调用方展示错误并允许重试或走游客入口。
   */
  static async register(nickname: string, grade: string): Promise<AuthResult> {
    const invalid: string = AuthClient.validateNickname(nickname);
    if (invalid.length > 0) {
      return { ok: false, user: null, source: 'local', message: invalid };
    }

    const result = await AgentApiClient.authRegister({
      nickname: nickname.trim(),
      grade: grade.length > 0 ? grade : undefined
    });
    if (!result.ok) {
      return { ok: false, user: null, source: 'local', message: AuthClient.describe(result) };
    }

    AuthStore.save(result.data.user, result.data.token, result.data.expiresAt);
    return {
      ok: true,
      user: result.data.user,
      source: 'local',
      message: `欢迎，${result.data.user.nickname}。已为你建立独立的学习画像。`
    };
  }

  // ---------------------------------------------------------------- 恢复
  /**
   * 启动时恢复登录态。
   *
   * 关键行为：**本地有 token 但校验失败时，降级为游客身份**，而不是报错卡住。
   * 理由——评审过程中一个过期 token 不该让整个 App 不可用。
   */
  static async restore(): Promise<AuthResult> {
    const session: StoredSession | null = AuthStore.getSession();
    if (session === null) {
      return { ok: false, user: null, source: 'guest', message: '' };
    }

    const result = await AgentApiClient.authMe();
    if (result.ok) {
      // 用服务端返回的权威信息刷新本地缓存（昵称/年级可能被后续功能修改）
      AuthStore.save(result.data.user, session.token, session.expiresAt);
      return { ok: true, user: result.data.user, source: 'restored', message: '' };
    }

    const failure = result as ApiFailure;
    if (failure.error.statusCode === 401) {
      // 凭据已失效：清掉本地登录态，退回游客身份
      AuthStore.clear();
      return {
        ok: false,
        user: null,
        source: 'guest',
        message: '登录已失效，已切换为体验身份。可在「我的」里重新登录。'
      };
    }
    // 网络类错误：保留本地登录态（可能只是暂时离线），按本地信息继续
    return {
      ok: true,
      user: {
        userId: session.userId,
        nickname: session.nickname,
        grade: session.grade,
        authProvider: session.authProvider,
        createdAt: '',
        lastLoginAt: ''
      },
      source: 'restored',
      message: '当前处于离线状态，正在使用本地保存的登录信息。'
    };
  }

  // ---------------------------------------------------------------- 退出 / 注销
  /** 退出登录：先尽力通知服务端吊销 token，再清本地（服务端失败不阻塞退出）。 */
  static async signOut(): Promise<AuthResult> {
    if (AuthStore.isSignedIn()) {
      await AgentApiClient.authLogout();
    }
    AuthStore.clear();
    return { ok: true, user: AuthClient.guestUser(), source: 'guest', message: '已退出登录。' };
  }

  /**
   * 注销账号（合规要求）。服务端标记停用并清空全部会话；
   * 本地无论成功与否都清空登录态，避免残留一个已失效的凭据。
   */
  static async deleteAccount(): Promise<AuthResult> {
    if (!AuthStore.isSignedIn()) {
      return { ok: false, user: null, source: 'guest', message: '当前未登录，无需注销。' };
    }
    const result = await AgentApiClient.authDeleteAccount();
    AuthStore.clear();
    if (!result.ok) {
      return { ok: false, user: null, source: 'guest', message: AuthClient.describe(result) };
    }
    return {
      ok: true,
      user: AuthClient.guestUser(),
      source: 'guest',
      message: '账号已注销，全部登录会话已失效。'
    };
  }

  // ---------------------------------------------------------------- 工具
  /** 把 ApiResult 失败转成用户能看懂的中文提示。 */
  private static describe(result: ApiResult<Object>): string {
    const failure = result as ApiFailure;
    if (failure.error.code === 'NETWORK_ERROR') {
      return '连接不上后端服务。请检查服务地址，或直接使用「一键体验」离线进入。';
    }
    return failure.error.message;
  }
}
