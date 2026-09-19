/**
 * 联调默认值单一真源（Single Source of Truth）
 *
 * 联调收敛后，前端只需要**一个** baseUrl：聊天层（/api/agent/chat）与结构化工作流层
 * （/api/v1/**）由同一个后端进程、同一个端口提供。因此这里只保留一个默认地址常量，
 * 页面里不允许再各写一份 IP。
 *
 * ⚠️ 不同运行环境的"宿主机地址"不同，务必按实际环境改 `DEFAULT_BASE_URL` 或
 * 在 App 的「接口环境」页里直接填（会持久化到 preferences，下次启动仍生效）：
 *
 *   ┌────────────────────────────┬──────────────────────────────┐
 *   │ 运行环境                    │ baseUrl                       │
 *   ├────────────────────────────┼──────────────────────────────┤
 *   │ 本机浏览器 / 桌面预览        │ http://127.0.0.1:5000         │
 *   │ HarmonyOS 模拟器            │ http://10.0.2.2:5000          │
 *   │ HarmonyOS 真机（同一 WiFi）  │ http://<开发机局域网IP>:5000   │
 *   │ Android 模拟器（ArkUI-X）    │ http://10.0.2.2:5000          │
 *   └────────────────────────────┴──────────────────────────────┘
 *
 * 真机联调查本机 IP：`ipconfig`（Windows）取"无线局域网适配器"的 IPv4 地址，
 * 并确认 Windows 防火墙放行 5000 端口入站。
 */
export class ApiDefaults {
  /** 默认后端地址。改这一处即可全局生效。 */
  static readonly DEFAULT_BASE_URL: string = 'http://10.0.2.2:5000';

  /** 本机回环地址，桌面预览 / 浏览器调试用。 */
  static readonly LOCALHOST_BASE_URL: string = 'http://127.0.0.1:5000';

  /** 契约版本，必须与 contracts/openapi.json 的 info.version 逐字一致。 */
  static readonly CONTRACT_VERSION: string = 'api-contract-v0.3';

  /** 单次请求超时（毫秒）。 */
  static readonly DEFAULT_TIMEOUT_MS: number = 8000;

  /**
   * 默认是否走离线 Fixture。
   * 默认 false：直接打真实后端，演示"真 Agent 循环"。
   * 无网络/无后端时可在「接口环境」页一键切到 Fixture。
   */
  static readonly DEFAULT_USE_FIXTURE: boolean = false;

  /**
   * 演示 / 游客身份的 userId。
   *
   * ⚠️ **必须与后端保持一致**：后端 `app/auth/service.py` 的 `DEMO_USER_ID`
   * 以及 `app/api/demo.py` 里预置的演示数据全部挂在 `demo-user` 上。
   *
   * 未登录、点了「一键体验」、或切到离线 Fixture 时，使用的都是这个身份——
   * 因此**加入登录功能不会改变任何演示数值**（mastery 42 / Plan V1 [30,30] /
   * √√× → 66.67 → 58）。
   */
  static readonly DEMO_USER_ID: string = 'demo-user';

  /** 演示身份的展示昵称（仅用于界面展示，不参与任何业务计算）。 */
  static readonly DEMO_USER_NAME: string = '小明';
}
