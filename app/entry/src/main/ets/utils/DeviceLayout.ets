import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'DeviceLayout';

/**
 * 设备形态 / 布局断点。
 *
 * 为什么需要
 * ----------
 * `module.json5` 声明了 `deviceTypes: ["phone", "tablet", "2in1"]`，但所有页面
 * 都是**按手机竖屏写死**的：卡片 `width('100%')`、无最大宽度、无断点。
 * 在平板或 PC 上跑，内容会被拉伸成很宽的一条，可读性反而比手机差 ——
 * 这就是"声明了三形态、实际只适配一种"的典型落差，也是项目名里
 * "全场景"被追问时最容易被抓的点。
 *
 * 本类只做一件事：**集中**判断当前属于哪一档，供页面读取。
 * 页面据此决定是否给正文加最大宽度约束、是否双列排布。
 *
 * 设计取舍
 * --------
 * 刻意**不做**一套完整的响应式组件库 —— 那会牵动全部 19 个页面，
 * 在无法编译验证的环境里风险过高。这里只提供"判断 + 一个最大宽度约束"，
 * 让改动**局部、可增量**：先让关键页面在大屏上不再拉伸，
 * 后续再逐页做双列布局（见 `docs/02` 的 P2 清单）。
 */
export class DeviceLayout {
  /** 断点档位：手机 / 平板 / 桌面（含 2in1）。 */
  static readonly PHONE: string = 'phone';
  static readonly TABLET: string = 'tablet';
  static readonly DESKTOP: string = 'desktop';

  /** 平板起始宽度（vp）。对齐 HarmonyOS 常见断点（sm < 600 ≤ md < 840 ≤ lg）。 */
  static readonly TABLET_MIN_WIDTH: number = 600;
  /** 桌面起始宽度（vp）。 */
  static readonly DESKTOP_MIN_WIDTH: number = 840;

  /**
   * 正文区最大宽度（vp）。
   *
   * 大屏上把内容限制在这个宽度内并居中，避免一行文本过长导致阅读困难。
   * 取值参考常见阅读舒适区（约 700–800vp）。
   */
  static readonly CONTENT_MAX_WIDTH: number = 720;

  private static widthVp: number = 0;
  private static breakpoint: string = DeviceLayout.PHONE;
  private static listenerRegistered: boolean = false;

  /** 当前窗口宽度（vp）；未初始化时为 0。 */
  static windowWidth(): number {
    return DeviceLayout.widthVp;
  }

  /** 当前断点档位（`phone` / `tablet` / `desktop`）。 */
  static current(): string {
    return DeviceLayout.breakpoint;
  }

  /** 是否大屏（平板或桌面）。 */
  static isLargeScreen(): boolean {
    return DeviceLayout.breakpoint !== DeviceLayout.PHONE;
  }

  /**
   * 正文区应使用的最大宽度（vp）。
   *
   * 手机上返回一个足够大的值，等价于"不约束" ——
   * 注意**不能返回 `Infinity`**：ArkUI 的 `constraintSize` 接受 `Length`，
   * 而 `Infinity` 不是合法的 `Length`，会导致布局异常。
   */
  static contentMaxWidth(): number {
    return DeviceLayout.isLargeScreen() ? DeviceLayout.CONTENT_MAX_WIDTH : 10000;
  }

  /**
   * 绑定主窗口并在尺寸变化时更新断点。
   *
   * 在 `EntryAbility.onWindowStageCreate` 里调用一次即可。
   * 失败不抛异常 —— 布局判断不该阻断启动。
   */
  static attach(windowStage: window.WindowStage): void {
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      DeviceLayout.update(mainWindow.getWindowProperties().windowRect.width);
      if (DeviceLayout.listenerRegistered) {
        return;
      }
      mainWindow.on('windowSizeChange', (size: window.Size) => {
        DeviceLayout.update(size.width);
      });
      DeviceLayout.listenerRegistered = true;
    } catch (error) {
      const typed = error as BusinessErrorLike;
      hilog.warn(DOMAIN, TAG, '%{public}s',
        `DeviceLayout.attach failed: ${typed.code} ${typed.message}`);
    }
  }

  /** 按宽度（px→vp 由调用方保证单位）重新判定档位。 */
  static update(widthVp: number): void {
    if (!(widthVp > 0)) {
      return;
    }
    DeviceLayout.widthVp = widthVp;
    if (widthVp >= DeviceLayout.DESKTOP_MIN_WIDTH) {
      DeviceLayout.breakpoint = DeviceLayout.DESKTOP;
    } else if (widthVp >= DeviceLayout.TABLET_MIN_WIDTH) {
      DeviceLayout.breakpoint = DeviceLayout.TABLET;
    } else {
      DeviceLayout.breakpoint = DeviceLayout.PHONE;
    }
  }

  /** 供测试与调试：把断点判定逻辑单独暴露（纯函数，不依赖窗口）。 */
  static classify(widthVp: number): string {
    if (!(widthVp > 0)) {
      return DeviceLayout.PHONE;
    }
    if (widthVp >= DeviceLayout.DESKTOP_MIN_WIDTH) {
      return DeviceLayout.DESKTOP;
    }
    if (widthVp >= DeviceLayout.TABLET_MIN_WIDTH) {
      return DeviceLayout.TABLET;
    }
    return DeviceLayout.PHONE;
  }

  /** 人类可读标签，供「接口环境」页之类的地方显示当前形态。 */
  static describe(): string {
    const label: string = DeviceLayout.breakpoint === DeviceLayout.DESKTOP ? '桌面 / 2in1'
      : (DeviceLayout.breakpoint === DeviceLayout.TABLET ? '平板' : '手机');
    return `${label}（${Math.round(DeviceLayout.widthVp)}vp）`;
  }
}

interface BusinessErrorLike {
  code: number;
  message: string;
}
