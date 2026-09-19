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
}

export interface AuthRegisterRequest {
  nickname: string;
  grade?: string;
}

export interface AuthLoginRequest {
  userId: string;
  token: string;
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
