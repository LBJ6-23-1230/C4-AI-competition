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
}
