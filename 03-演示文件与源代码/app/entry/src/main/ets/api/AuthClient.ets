import { ApiDefaults } from './ApiDefaults';
import { AgentApiClient } from './AgentApiClient';
import { ApiFailure, ApiResult } from './ApiResult';
import { AuthResult } from './AuthResult';
import { AuthStore } from './AuthStore';
import { AuthUser, NICKNAME_MAX_LENGTH, NICKNAME_MIN_LENGTH, StoredSession, VERIFICATION_CODE_MESSAGES, AuthVerifyCodeRequest } from './AuthModels';
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

  /**
   * 离线 Fixture 模式下的统一拦截。
   *
   * 修复的缺陷：`FixtureApiTransport` **一条 auth 路由都没有**（它只覆盖工作流 /
   * 知识库 / 画像那些）。于是只要 App 处于离线模式，登录页上每一个入口 ——
   * 注册、昵称登录、手机号、验证码、华为账号 —— 都会直连传输层、掉进兜底分支，
   * 把内部错误原样显示给用户：
   *
   *     未找到 fixture 路由：POST /api/v1/auth/login-or-register
   *
   * 离线时**不可能**在服务器上建号，所以这里如实说明并给出两条出路，
   * 而**不伪装成功** —— 假装注册成功会让用户以为账号已创建、实际拿到的却是
   * demo-user，那正是本项目一直拒绝做的那种"静默伪装"（见 README 的降级纪律）。
   *
   * 注意：这不等于把用户挡在登录页 —— 「跳过登录，用演示身份进入」一直在，且
   * `EntryAbility` 在离线模式下也不会把已登录用户拉回登录页。
   */
  private static offlineUnavailable(): AuthResult {
    return {
      ok: false,
      user: null,
      source: 'fixture',
      message: '当前是「离线 Fixture」模式：不连服务器，因此无法注册或登录真实账号。'
        + '要注册/登录，请先到「我的 → 接口环境」切回联机模式；'
        + '要直接体验，点下方「跳过登录，用演示身份进入」即可。'
    };
  }

  /** 把本地保存的会话还原成 `AuthUser`（离线时用它，不打扰服务端）。 */
  private static sessionUser(session: StoredSession): AuthUser {
    return {
      userId: session.userId,
      nickname: session.nickname,
      grade: session.grade,
      authProvider: session.authProvider,
      createdAt: '',
      lastLoginAt: ''
    };
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
   *
   * ⚠️ `phone` 是**必填**（契约 `AuthRegisterRequest.required = [nickname, phone]`，
   * 后端 `_PHONE_REQUIRED = True`）。这里把它提成必填参数而不是可选，
   * 是为了让"忘记传手机号"变成**编译期错误**而不是运行期 400。
   *
   * 修复的历史缺陷：该方法原先签名为 `register(nickname, grade)`，
   * **从不发送 phone** —— 任何调用点都必然得到
   * `400 VALIDATION_ERROR 手机号不能为空`。因为当时没有调用点，
   * 它是一颗休眠炸弹：谁按注释去用它就会踩。
   * 现在类型层面挡住了这条路。
   */
  static async register(nickname: string, phone: string, grade?: string): Promise<AuthResult> {
    if (AgentApiClient.getConfig().useFixture) {
      return AuthClient.offlineUnavailable();
    }
    const invalid: string = AuthClient.validateNickname(nickname);
    if (invalid.length > 0) {
      return { ok: false, user: null, source: 'local', message: invalid };
    }

    const result = await AgentApiClient.authRegister({
      nickname: nickname.trim(),
      phone: phone.trim(),
      grade: grade !== undefined && grade.length > 0 ? grade : undefined
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
  static async loginOrRegister(nickname: string, grade: string, phone?: string,
    password?: string): Promise<AuthResult> {
    if (AgentApiClient.getConfig().useFixture) {
      return AuthClient.offlineUnavailable();
    }
    const invalid: string = AuthClient.validateNickname(nickname);
    if (invalid.length > 0) {
      return { ok: false, user: null, source: 'local', message: invalid };
    }

    const result = await AgentApiClient.authLoginOrRegister({
      nickname: nickname.trim(),
      grade: grade.length > 0 ? grade : undefined,
      phone: phone !== undefined && phone.length > 0 ? phone : undefined,
      password: password !== undefined && password.length > 0 ? password : undefined
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
   * ⚠️ **本方法不做验证码校验**：它保留了"知道手机号即可登录"的语义，
   * 只适合演示与单机环境。产品路径应当用
   * `sendVerificationCode()` + `verifyCode()` 两个方法（见下）。
   */
  static async loginByPhone(phone: string, password?: string): Promise<AuthResult> {
    if (AgentApiClient.getConfig().useFixture) {
      return AuthClient.offlineUnavailable();
    }
    const trimmed: string = phone.trim();
    if (trimmed.length === 0) {
      return { ok: false, user: null, source: 'local', message: '请输入手机号。' };
    }
    const result = await AgentApiClient.authLogin({
      phone: trimmed,
      password: password !== undefined && password.length > 0 ? password : undefined
    });
    if (!result.ok) {
      return { ok: false, user: null, source: 'local', message: AuthClient.describe(result) };
    }
    AuthStore.save(result.data.user, result.data.token, result.data.expiresAt);
    return {
      ok: true,
      user: result.data.user,
      // ⚠️ 这里是**用户主动登录**（手机号 / 昵称 + 密码），来源必须是 `local`。
      // 原实现沿用了 `restored`，而 `restored` 的语义是"冷启动时用本地 token
      // 恢复登录态"（只有 `restore()` 该用它）。后果：「我的 → 账号与密码管理」
      // 把刚主动登录的账号标成「已恢复的登录态」，文案与事实相反。
      source: 'local',
      message: `欢迎回来，${result.data.user.nickname}。`
    };
  }

  // -------------------------------------------------------- 手机号验证码登录
  /**
   * 发送验证码。
   *
   * 返回的 `AuthResult.message` 在成功时是**给用户看的真实提示**：
   *   · `smsDelivered === true`  → 「验证码已发送至 138****8888」
   *   · `smsDelivered === false` → 明确说明**短信并未真的发出**，并给出开发回显码
   *
   * 之所以这么强调：后端专门设计了 `smsDelivered` 字段来区分"真发了"与
   * "只是回显"，前端若一律显示"已发送"就浪费了这个设计，也违背项目
   * "不伪装"的纪律。`devCode` 只在开发模式存在，界面上要标注成开发回显。
   */
  static async sendVerificationCode(phone: string): Promise<AuthResult> {
    if (AgentApiClient.getConfig().useFixture) {
      return AuthClient.offlineUnavailable();
    }
    const trimmed: string = phone.trim();
    if (trimmed.length === 0) {
      return { ok: false, user: null, source: 'local', message: '请输入手机号。' };
    }
    const result = await AgentApiClient.authSendCode({ phone: trimmed });
    if (!result.ok) {
      return { ok: false, user: null, source: 'local', message: AuthClient.describe(result) };
    }
    const data = result.data;
    const devCode: string = data.devCode !== undefined && data.devCode.length > 0
      ? data.devCode : '';
    let message: string;
    if (data.smsDelivered) {
      message = `验证码已发送至 ${data.phoneMasked}，${AuthClient.describeSeconds(data.expiresInSeconds)}内有效。`;
    } else if (devCode.length > 0) {
      message = `短信服务未接入，当前为开发模式回显：验证码是 ${devCode}（${AuthClient.describeSeconds(data.expiresInSeconds)}内有效）。`;
    } else {
      message = `短信服务未接入，未能真实下发验证码。可改用「昵称登录」或「一键体验」。`;
    }
    return {
      ok: true,
      user: null,
      source: 'local',
      message: message,
      resendAfterSeconds: data.resendAfterSeconds,
      devCode: devCode,
      smsDelivered: data.smsDelivered
    };
  }

  /**
   * 校验验证码并登录 / 自动注册（登录优先）。
   *
   * `nickname` / `grade` 只在**首次建号**时生效；手机号已注册时被后端忽略，
   * 因此可以放心一并传上，不需要前端先探测"这个号存不存在"。
   */
  static async verifyCode(phone: string, code: string,
    nickname?: string, grade?: string): Promise<AuthResult> {
    if (AgentApiClient.getConfig().useFixture) {
      return AuthClient.offlineUnavailable();
    }
    const trimmedPhone: string = phone.trim();
    const trimmedCode: string = code.trim();
    if (trimmedPhone.length === 0) {
      return { ok: false, user: null, source: 'local', message: '请输入手机号。' };
    }
    if (!/^\d{6}$/.test(trimmedCode)) {
      return { ok: false, user: null, source: 'local', message: '请输入 6 位数字验证码。' };
    }
    const request: AuthVerifyCodeRequest = { phone: trimmedPhone, code: trimmedCode };
    if (nickname !== undefined && nickname.trim().length > 0) {
      request.nickname = nickname.trim();
    }
    if (grade !== undefined && grade.length > 0) {
      request.grade = grade;
    }

    const result = await AgentApiClient.authVerifyCode(request);
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

  /** 把秒数说成人话（避免界面出现 "300 秒" 这种不直观的表述）。 */
  private static describeSeconds(seconds: number): string {
    if (seconds >= 60 && seconds % 60 === 0) {
      return `${seconds / 60} 分钟`;
    }
    return `${seconds} 秒`;
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
    if (AgentApiClient.getConfig().useFixture) {
      return AuthClient.offlineUnavailable();
    }
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
  static async loginByNickname(nickname: string, password?: string): Promise<AuthResult> {
    if (AgentApiClient.getConfig().useFixture) {
      return AuthClient.offlineUnavailable();
    }
    const invalid: string = AuthClient.validateNickname(nickname);
    if (invalid.length > 0) {
      return { ok: false, user: null, source: 'local', message: invalid };
    }

    const result = await AgentApiClient.authLogin({
      nickname: nickname.trim(),
      password: password !== undefined && password.length > 0 ? password : undefined
    });
    if (!result.ok) {
      return { ok: false, user: null, source: 'local', message: AuthClient.describe(result) };
    }

    AuthStore.save(result.data.user, result.data.token, result.data.expiresAt);
    return {
      ok: true,
      user: result.data.user,
      // ⚠️ 这里是**用户主动登录**（手机号 / 昵称 + 密码），来源必须是 `local`。
      // 原实现沿用了 `restored`，而 `restored` 的语义是"冷启动时用本地 token
      // 恢复登录态"（只有 `restore()` 该用它）。后果：「我的 → 账号与密码管理」
      // 把刚主动登录的账号标成「已恢复的登录态」，文案与事实相反。
      source: 'local',
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

    // 离线 Fixture 模式：不做网络校验，直接用本地保存的身份
    // （与 `EntryAbility.restoreIdentity()` 的「规则 2」一致）。
    //
    // ⚠️ 原实现是"绕过"的：`authMe()` 掉进 fixture 兜底 → `statusCode` 为 undefined
    // → 恰好不等于 401 → 落到下面的"网络类错误"分支。结果对，但**依赖那个巧合**：
    // 一旦以后给 fixture 补上 `/api/v1/auth/me`（或其错误码变了），
    // 每次离线启动都会把已登录用户登出。现在把意图写明。
    if (AgentApiClient.getConfig().useFixture) {
      return {
        ok: true,
        user: AuthClient.sessionUser(session),
        source: 'restored',
        message: '当前为离线 Fixture 模式，正在使用本地保存的登录信息。'
      };
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
    // 保留本地登录态（可能只是暂时离线），按本地信息继续。
    //
    // ⚠️ 但不能一律说成"离线"。`statusCode` 为 `undefined` 才是**真没连上**；
    // 若服务端明明回了、只是状态码不是 401（例如契约版本不符的 409、或 5xx），
    // 说成"离线状态"会让用户以为等一会儿就好 —— 实际重试永远不会好转。
    // 这里如实区分，行为不变（仍然按本地身份继续，不把用户挡在门外）。
    const statusCode: number | undefined = (result as ApiFailure).error.statusCode;
    const offlineLike: boolean = statusCode === undefined || statusCode === 0;
    return {
      ok: true,
      user: AuthClient.sessionUser(session),
      source: 'restored',
      message: offlineLike
        ? '当前处于离线状态，正在使用本地保存的登录信息。'
        : `服务端校验返回 HTTP ${statusCode}，已按本地保存的登录信息继续。`
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
    // 离线 Fixture 模式：联系不上服务端，停用不了服务器账号。
    // 仍然清掉本机登录态（与"本地无论成功与否都清空"的纪律一致），但**如实说明**
    // 服务器账号还在 —— 不能让用户以为注销成功了。
    if (AgentApiClient.getConfig().useFixture) {
      AuthStore.clear();
      return {
        ok: true,
        user: AuthClient.guestUser(),
        source: 'fixture',
        message: '当前是「离线 Fixture」模式：已清除本机登录态并回到体验身份，'
          + '但**服务器上的账号未被停用**（离线联系不上服务端）。'
          + '要真正注销，请先到「我的 → 接口环境」切回联机模式。'
      };
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
    // 验证码相关的 8 个错误码有专门文案（见 AuthModels.VERIFICATION_CODE_MESSAGES）。
    // 后端把 errorCode 放在响应的 errorCode 字段里，由 AgentApiClient 透传成 error.code。
    const mapped: string | undefined = VERIFICATION_CODE_MESSAGES[failure.error.code];
    if (mapped !== undefined && mapped.length > 0) {
      return mapped;
    }
    return failure.error.message;
  }
}
