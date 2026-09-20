import { ApiDefaults } from './ApiDefaults';
import { AgentApiClient } from './AgentApiClient';
import { ApiFailure, ApiResult } from './ApiResult';
import { AuthResult } from './AuthResult';
import { AuthStore } from './AuthStore';
import { AuthUser, NICKNAME_MAX_LENGTH, NICKNAME_MIN_LENGTH, StoredSession } from './AuthModels';
import { HuaweiAccountService, HuaweiAuthOutcome } from '../services/HuaweiAccountService';

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

  /**
   * **登录优先，注册兜底** —— 登录页主按钮应当调这个。
   *
   * 修复的问题：此前"登录"与"注册"两个标签实际都只调 `register()`，
   * 于是用同一个昵称再点一次会**又建一个新账号**（实测两次注册「张三」
   * 得到两个不同 userId），用户以为在登录、实际旧画像永远读不到。
   *
   * 现在由服务端判定：昵称已存在就登录、不存在才建号，响应里的 `created`
   * 用于区分文案。
   */
  static async loginOrRegister(nickname: string, grade: string, phone?: string): Promise<AuthResult> {
    const invalid: string = AuthClient.validateNickname(nickname);
    if (invalid.length > 0) {
      return { ok: false, user: null, source: 'local', message: invalid };
    }

    const result = await AgentApiClient.authLoginOrRegister({
      nickname: nickname.trim(),
      grade: grade.length > 0 ? grade : undefined,
      phone: phone !== undefined && phone.length > 0 ? phone : undefined
    });
    if (!result.ok) {
      return { ok: false, user: null, source: 'local', message: AuthClient.describe(result) };
    }

    AuthStore.save(result.data.user, result.data.token, result.data.expiresAt);
    return {
      ok: true,
      user: result.data.user,
      source: 'local',
      message: result.data.created
        ? `已为你建立账号，${result.data.user.nickname}。`
        : `欢迎回来，${result.data.user.nickname}。`
    };
  }

  /**
   * 按手机号免密登录（**账号必须已存在**）。
   *
   * 手机号是唯一身份标识，比昵称可靠 —— 所以登录页优先用它。
   *
   * ⚠️ 当前版本**不做短信验证码**：真实场景必须先验证码证明"号是本人的"。
   * 完整链路见 `docs/11-用户登录体系方案.md` §5.2。
   */
  static async loginByPhone(phone: string): Promise<AuthResult> {
    const trimmed: string = phone.trim();
    if (trimmed.length === 0) {
      return { ok: false, user: null, source: 'local', message: '请输入手机号。' };
    }
    const result = await AgentApiClient.authLogin({ phone: trimmed });
    if (!result.ok) {
      return { ok: false, user: null, source: 'local', message: AuthClient.describe(result) };
    }
    AuthStore.save(result.data.user, result.data.token, result.data.expiresAt);
    return {
      ok: true,
      user: result.data.user,
      source: 'restored',
      message: `欢迎回来，${result.data.user.nickname}。`
    };
  }

  /**
   * 华为账号一键登录（鸿蒙赛道最对口的登录方式）。
   *
   * 走 `@kit.AccountKit` 的 `authentication` 模块拿到华为账号的 OpenID，
   * 再交给本服务换取自己的 token。免注册、免验证码。
   *
   * ⚠️ **前置条件（缺一不可）**：
   *   1. 在 AppGallery Connect 创建应用并开通「华为账号」能力
   *   2. DevEco 中把 `client_id` 配到 `module.json5` 的 metadata
   *   3. 应用签名证书指纹已在 AGC 登记
   *
   * 缺任何一条都会在 `executeRequest` 阶段失败。这里把失败原因
   * **原样返回给用户**，不静默降级成"登录成功"。
   */
  static async loginWithHuaweiAccount(): Promise<AuthResult> {
    const outcome: HuaweiAuthOutcome = await HuaweiAccountService.requestOpenId();
    if (!outcome.ok) {
      return { ok: false, user: null, source: 'local', message: outcome.message };
    }
    const result = await AgentApiClient.authLoginWithHuawei({
      openId: outcome.openId,
      unionId: outcome.unionId,
      nickname: outcome.nickname
    });
    if (!result.ok) {
      return { ok: false, user: null, source: 'local', message: AuthClient.describe(result) };
    }
    AuthStore.save(result.data.user, result.data.token, result.data.expiresAt);
    return {
      ok: true,
      user: result.data.user,
      source: 'local',
      message: result.data.created
        ? `已用华为账号建立账号，${result.data.user.nickname}。`
        : `欢迎回来，${result.data.user.nickname}。`
    };
  }

  /**
   * 按昵称免密登录（**账号必须已存在**）。
   *
   * 与 `loginOrRegister` 的区别：这里不会建号，昵称不存在时明确报错。
   * 换设备、清过应用数据后想登回原账号时用它。
   *
   * ⚠️ 昵称不是秘密，因此这不是安全的认证方式，仅适用于演示/单机场景。
   * 真实身份校验请见 `docs/11-用户登录体系方案.md` 的手机号验证码方案。
   */
  static async loginByNickname(nickname: string): Promise<AuthResult> {
    const invalid: string = AuthClient.validateNickname(nickname);
    if (invalid.length > 0) {
      return { ok: false, user: null, source: 'local', message: invalid };
    }

    const result = await AgentApiClient.authLogin({ nickname: nickname.trim() });
    if (!result.ok) {
      return { ok: false, user: null, source: 'local', message: AuthClient.describe(result) };
    }

    AuthStore.save(result.data.user, result.data.token, result.data.expiresAt);
    return {
      ok: true,
      user: result.data.user,
      source: 'restored',
      message: `欢迎回来，${result.data.user.nickname}。`
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
