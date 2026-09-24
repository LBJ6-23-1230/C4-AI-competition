import { authentication } from '@kit.AccountKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN: number = 0x5A02;
const TAG: string = 'HuaweiAccount';

/**
 * 华为账号登录结果。
 *
 * 用显式的 `ok` 而不是抛异常：调用方在 UI 层，需要把失败原因
 * **原样展示给用户**（尤其是"未配置 client_id"这类可修复的配置问题）。
 */
export interface HuaweiAuthOutcome {
  ok: boolean;
  openId: string;
  unionId: string;
  nickname: string;
  message: string;
}

/**
 * 华为账号服务（鸿蒙全场景能力之一）。
 *
 * 为什么这是鸿蒙赛道最对口的登录方式
 * ----------------------------------
 * * **免注册**：用户不需要填昵称、手机号、验证码
 * * **免验证码**：不存在短信轰炸与成本问题
 * * **跨设备**：同一华为账号在手机 / 平板 / PC 上是同一个身份，
 *   天然支撑"全场景"叙事 —— 换设备不需要重新注册
 *
 * ⚠️ 前置条件（缺一不可，缺任何一条都会失败）
 * ------------------------------------------
 *   1. 在 AppGallery Connect 创建应用并开通「华为账号」能力
 *   2. 申请 `client_id` 并写入 `module.json5` 的 metadata：
 *      ```json5
 *      "metadata": [
 *        { "name": "client_id", "value": "你的 client_id" }
 *      ]
 *      ```
 *   3. 应用签名证书指纹已在 AGC 登记
 *
 * **本函数不做静默降级**：拿不到 OpenID 就如实返回失败与原因，
 * 绝不返回一个假的"登录成功"。
 */
export class HuaweiAccountService {
  /**
   * 拉起华为账号授权，取得 OpenID。
   *
   * 只申请 `OPEN_ID` 与 `UNION_ID` 两种标识：
   * * `OPEN_ID`  —— **应用内唯一**，同一个华为账号在不同应用里值不同。
   *   本地建号时用它做身份键，天然避免跨应用追踪。
   * * `UNION_ID` —— **开发者账号内唯一**，将来有多个应用时可打通。
   *
   * 刻意**不申请**手机号、头像、昵称等敏感 scope：
   * 当前功能不需要，少要权限就少一份合规负担。
   */
  static async requestOpenId(): Promise<HuaweiAuthOutcome> {
    try {
      const provider: authentication.HuaweiIDProvider = new authentication.HuaweiIDProvider();
      const request: authentication.LoginWithHuaweiIDRequest = provider.createLoginWithHuaweiIDRequest();
      request.forceLogin = false;
      request.state = 'zhixue-mate-login';

      const controller: authentication.AuthenticationController =
        new authentication.AuthenticationController();

      const response: authentication.LoginWithHuaweiIDResponse =
        await controller.executeRequest(request) as authentication.LoginWithHuaweiIDResponse;
      const credential: authentication.LoginWithHuaweiIDCredential | undefined = response.data;
      const openId: string = credential?.openID.trim() ?? '';
      const unionId: string = credential?.unionID.trim() ?? '';
      if (openId.length === 0) {
        return HuaweiAccountService.failure(
          '华为账号授权已返回，但未取到 OpenID。请确认 AGC 已开通「华为账号」能力。');
      }
      return {
        ok: true, openId: openId, unionId: unionId,
        nickname: '',
        message: '华为账号授权成功。'
      };
    } catch (error) {
      const typed: BusinessError = error as BusinessError;
      hilog.warn(DOMAIN, TAG, '%{public}s', `Huawei auth failed: ${typed.code} ${typed.message}`);
      return HuaweiAccountService.failure(HuaweiAccountService.explain(typed));
    }
  }

  /** 把 SDK 错误码翻译成用户能看懂、且**可据此行动**的提示。 */
  private static explain(error: BusinessError): string {
    const code: number = error.code;
    // 常见错误码（Account Kit）：1001502001 未登录华为账号；
    // 1001502002 未授权；1001502003 参数错误；其余归为配置问题。
    if (code === 1001502001) {
      return '请先在系统「设置」里登录华为账号，再使用华为账号一键登录。';
    }
    if (code === 1001502002) {
      return '你取消了华为账号授权。可以改用手机号或昵称登录。';
    }
    if (code === 1001502003) {
      return '华为账号登录参数有误，请检查 AGC 的 client_id 配置。';
    }
    return `华为账号登录未完成（错误码 ${code}）。`
      + '通常是因为尚未在 AppGallery Connect 配置 client_id 与签名指纹；'
      + '此时请改用手机号或昵称登录。';
  }

  private static failure(message: string): HuaweiAuthOutcome {
    return { ok: false, openId: '', unionId: '', nickname: '', message: message };
  }
}
