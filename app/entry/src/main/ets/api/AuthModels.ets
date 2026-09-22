/**
 * 鉴权 DTO —— 与 `contracts/openapi.json` 的 Auth* 定义逐字段对应。
 *
 * 设计要点：**没有密码字段**。本项目的登录是"昵称即身份 + 长期 token"，
 * 不做密码体系（见 docs/02-登录界面设计与用户数据库方案.md §4.2）。
 */

/** 认证来源。local = 本服务免密注册；guest = 演示/游客身份。 */
export type AuthProvider = 'local' | 'guest' | 'agc_phone' | 'agc_anonymous';

/** 登录态来源，用于界面标注与调试。 */
export type AuthSource = 'guest' | 'local' | 'restored' | 'fixture';

/** 对外用户视图。后端保证不含 token / authSubject。 */
export interface AuthUser {
  userId: string;
  nickname: string;
  grade: string;
  authProvider: AuthProvider;
  createdAt: string;
  lastLoginAt: string;
  /** 脱敏手机号（`138****0000`）。服务端**不回传完整号码**。 */
  phoneMasked?: string;
  hasPhone?: boolean;
}

export interface AuthRegisterRequest {
  nickname: string;
  grade?: string;
  /**
   * 手机号。**注册必填**（唯一身份标识）；后端做格式校验与唯一约束。
   *
   * ⚠️ 声明为必填（而非 `phone?`）是刻意的：契约里
   * `AuthRegisterRequest.required = [nickname, phone]`，后端 `_PHONE_REQUIRED = True`，
   * 少了它必然 400。原来的可选声明让"漏传"能通过类型检查、
   * 到运行时才以 400 暴露 —— `AuthClient.register()` 就曾因此成为休眠炸弹。
   */
  phone: string;
}

/**
 * 华为账号登录请求。
 *
 * 客户端用 `@kit.AccountKit` 拿到 OpenID 后交给服务端换取本服务的 token。
 * 服务端**不校验 OpenID 的真伪**（那需要调用华为的服务端接口验签），
 * 因此这条链路在当前版本是"演示可用、生产需补验签"，见 `docs/13`。
 */
export interface AuthHuaweiLoginRequest {
  openId: string;
  unionId?: string;
  nickname?: string;
  grade?: string;
}

/**
 * 登录请求。三种形式，服务端按优先级分派：
 *   · `{userId, token}` —— 恢复本机已保存的登录态（最高优先）
 *   · `{phone}`         —— 按手机号登录（**免验证码**，保留给演示与单机环境）
 *   · `{nickname}`      —— 按昵称免密登录
 *
 * ⚠️ 生产环境应走验证码链路（`AuthSendCodeRequest` + `AuthVerifyCodeRequest`），
 * 见 `AuthClient.sendVerificationCode()` / `verifyCode()`。
 */
export interface AuthLoginRequest {
  userId?: string;
  token?: string;
  nickname?: string;
  phone?: string;
}

// ------------------------------------------------------------------ 手机号验证码
/**
 * 发送验证码请求。字段与契约 `PhoneCodeSendRequest` 一致。
 *
 * `phone` 支持 `+86` 前缀与空格/短横线分隔写法，后端会归一化成 11 位。
 */
export interface AuthSendCodeRequest {
  phone: string;
}

/**
 * 发送验证码响应。字段与契约 `PhoneCodeSendResponse` 一致。
 *
 * **诚实标注**：`smsDelivered === false` 表示短信**并没有真的发出去**
 * （未配置短信服务商），此时后端仅在非生产环境回显 `devCode` 供联调使用。
 * 界面必须据此如实提示，不得显示成"验证码已发送"。
 */
export interface AuthSendCodeResponse {
  /** 脱敏手机号，如 `138****8888`。后端绝不回传完整号码。 */
  phoneMasked: string;
  /** 验证码有效期（秒）。 */
  expiresInSeconds: number;
  /** 多少秒后才能重新发送（当前 60）。按钮倒计时用它，不要写死。 */
  resendAfterSeconds: number;
  /** true 才代表短信服务商已实际发送。 */
  smsDelivered: boolean;
  /** 仅开发模式回显；生产模式绝不返回。可空。 */
  devCode?: string;
}

/**
 * 校验验证码并登录或自动注册。字段与契约 `PhoneCodeVerifyRequest` 一致。
 *
 * `nickname` / `grade` **仅在首次自动注册时**使用；手机号已存在时被忽略。
 */
export interface AuthVerifyCodeRequest {
  phone: string;
  /** 6 位数字验证码，一次性使用。 */
  code: string;
  nickname?: string;
  grade?: string;
}

/** 验证码相关后端错误码 → 用户可读文案。见契约 `ErrorResponse.enum`。 */
export const VERIFICATION_CODE_MESSAGES: Record<string, string> = {
  'RATE_LIMITED': '发送太频繁了，请稍后再试。',
  'DAILY_LIMIT_REACHED': '今日验证码次数已用完，请明天再试。',
  'PHONE_LOCKED': '连续输错次数过多，该手机号已被临时锁定，请 15 分钟后再试。',
  'INVALID_CODE': '验证码不正确，请检查后重试。',
  'CODE_EXPIRED': '验证码已过期，请重新获取。',
  'CODE_NOT_FOUND': '请先获取验证码。',
  'SMS_NOT_CONFIGURED': '短信服务尚未配置，暂时无法发送验证码。可改用「昵称登录」或「一键体验」。',
  'SMS_PROVIDER_UNAVAILABLE': '短信服务暂不可用，请稍后重试。可改用「昵称登录」或「一键体验」。'
};

/**
 * 「登录优先，注册兜底」的请求/响应。
 *
 * 这是登录页主按钮应当调用的接口：昵称已存在就登录、不存在才建号，
 * 从而避免"用同一个昵称再点一次又建一个新账号"（此前实测会得到两个 userId）。
 */
export interface AuthLoginOrRegisterRequest {
  nickname: string;
  grade?: string;
  phone?: string;
}

export interface AuthLoginOrRegisterResponse extends AuthSessionResponse {
  /** true = 本次新建了账号；false = 登录了已有账号。用于文案区分。 */
  created: boolean;
}

export interface AuthSessionResponse {
  user: AuthUser;
  token: string;
  expiresAt: string;
}

export interface AuthUserResponse {
  user: AuthUser;
}

export interface AuthStatusResponse {
  status: string;
  userId?: string;
}

/**
 * 设备本地保存的登录态。
 *
 * 注意：`token` 是凭据，与 `user` 分开存放——user 用于首屏渲染，
 * token 只在请求头里出现，**不进任何日志或界面**。
 */
export interface StoredSession {
  userId: string;
  token: string;
  expiresAt: string;
  nickname: string;
  grade: string;
  authProvider: AuthProvider;
  savedAt: string;
}

/** 可选的年级白名单，与后端 `service._ALLOWED_GRADES` 保持一致。 */
export const GRADE_OPTIONS: string[] = [
  '大一', '大二', '大三', '大四', '大五', '研一', '研二', '研三', '博士'
];

/** 昵称长度约束，与后端校验保持一致。 */
export const NICKNAME_MIN_LENGTH: number = 1;
export const NICKNAME_MAX_LENGTH: number = 16;

/** 手机号脱敏：138****8888。演示工程不存明文手机号，此函数供账号页展示用。 */
export function maskPhone(phone: string): string {
  if (phone.length < 7) {
    return phone;
  }
  return `${phone.substring(0, 3)}****${phone.substring(phone.length - 4)}`;
}
