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
  /** 手机号。**注册必填**（唯一身份标识）；后端做格式校验与唯一约束。 */
  phone?: string;
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
 * 登录请求。两种形式，服务端按"给了 userId/token 就优先按凭据恢复，
 * 否则按昵称登录"分派：
 *   · `{userId, token}` —— 恢复本机已保存的登录态
 *   · `{phone}`         —— 按手机号登录（当前演示版未接短信验证码）
 *   · `{nickname}`      —— 按昵称免密登录
 */
export interface AuthLoginRequest {
  userId?: string;
  token?: string;
  nickname?: string;
  phone?: string;
}

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
