import { AuthSource, AuthUser } from './AuthModels';

/**
 * 登录流程的统一返回类型。
 *
 * 刻意不用 `ApiResult<T>`：登录的语义与「接口调用」不同——
 * 「游客进入」是一个**成功**结果，但它根本没有发起网络请求；
 * 而「注册失败」需要同时携带可展示的中文原因与可回退的建议。
 */
export interface AuthResult {
  /** 是否可进入 App。true = 可以继续（含游客兜底）。 */
  ok: boolean;
  /** 登录用户；ok=false 时为 null。 */
  user: AuthUser | null;
  /** 身份来源，用于界面标注与调试。 */
  source: AuthSource;
  /** 给用户看的中文说明，可为空串。 */
  message: string;
  /**
   * 距离可重发验证码还有多少秒（仅 `sendVerificationCode()` 会填）。
   *
   * **不要在前端写死 60** —— 后端 `VERIFICATION_RESEND_SECONDS` 是可配的，
   * 倒计时用这个值才与后端限流真实一致。
   */
  resendAfterSeconds?: number;
  /**
   * 开发模式回显的验证码（仅 `sendVerificationCode()` 且后端未接短信时存在）。
   *
   * ⚠️ 界面上必须**明确标注这是开发回显**，不能显示成"短信已发送"。
   */
  devCode?: string;
  /**
   * 短信是否**真的**发出去了（仅 `sendVerificationCode()` 会填）。
   *
   * false 表示后端只在开发模式回显了验证码，并没有真实下发 ——
   * 这是后端专门设计的诚实标注字段，前端必须如实呈现。
   */
  smsDelivered?: boolean;
}
