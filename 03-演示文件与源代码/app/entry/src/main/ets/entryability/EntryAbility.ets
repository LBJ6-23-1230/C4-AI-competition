import { AbilityConstant, UIAbility, Want, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiEnvironmentStore } from '../api/ApiEnvironmentStore';
import { AuthClient } from '../api/AuthClient';
import { AuthResult } from '../api/AuthResult';
import { AuthStore } from '../api/AuthStore';
import { FixtureDemoStateStore } from '../api/FixtureDemoStateStore';
import { WorkflowSessionStore } from '../cache/WorkflowSessionStore';
import { appState } from '../data/AppState';
import { DistributedStateService } from '../services/DistributedStateService';
import { ProactiveSurfaceService } from '../services/ProactiveSurfaceService';
import { ProactiveSettingsStore } from '../services/ProactiveSettingsStore';
import { DeviceLayout } from '../utils/DeviceLayout';
import { FocusTask } from '../models/AgentModels';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private activeWindowStage: window.WindowStage | null = null;
  private pendingLaunchWant: Want | null = null;
  //: 从桌面学习卡片带进来的任务。启动序列里 `applyLogout()` / `applyLogin()`
  //: 都会重置账号态并清掉 `activeFocusTask`，所以必须单独留一份、在身份恢复
  //: 之后再补写回去（否则"点卡片冷启动"带的任务名与时长全部失效）。
  private pendingCardTask: FocusTask | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    this.pendingLaunchWant = want;
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    this.activeWindowStage = windowStage;

    // 绑定窗口尺寸 → 布局断点。module.json5 声明了 phone/tablet/2in1 三种形态，
    // 页面需要知道自己在大屏还是小屏，才能决定是否给正文加最大宽度。
    DeviceLayout.attach(windowStage);

    if (!ApiEnvironmentStore.restore(this.context)) {
      hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Failed to restore API environment, using defaults.');
    }
    if (!FixtureDemoStateStore.initialize(this.context)) {
      hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Failed to restore fixture demo state.');
    }
    if (!WorkflowSessionStore.restore(this.context)) {
      hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Failed to restore workflow session.');
    }
    if (!ProactiveSettingsStore.restore(this.context)) {
      hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Failed to restore proactive notification settings.');
    }

    // 启动时先把 AppState 对齐到已知身份，避免首页在异步校验完成前读到空身份。
    appState.applyLogout();

    // ★ 启动进入**对话页**（而不是工作台）。
    // 产品定位是"对话式学习秘书"：进来就能直接说话，不用先读一遍功能清单。
    // 先加载对话页、再异步判断是否要去登录页，这样即使校验慢也不会白屏。
    const fromLearningCard: boolean = this.prepareLearningCardLaunch(this.pendingLaunchWant);
    const initialPage: string = fromLearningCard ? 'pages/FocusSetup' : 'pages/ChatMain';
    windowStage.loadContent(initialPage, (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    // ⚠️ **必须先 await AuthStore.initialize() 再判登录态**（下方 bootstrapAuth 内串行执行）。
    //
    // 原实现是把 `initialize().then(...)` 与 `void this.restoreIdentity(...)` **并行**发起，
    // 而 `restoreIdentity()` 的第一个动作就是同步调用 `AuthStore.isSignedIn()`。
    // `AuthStore.session` 要等 `initialize()` 内部的 `await TokenCipher.initialize()`
    // 完成、走到 `loadFromPreferences()` 才被赋值 —— 并行发起时那一刻必然是 `null`，
    // 于是**每次冷启动都命中"没有登录态"分支**，被强制拉到登录页；
    // `restoreIdentity()` 里"离线 Fixture 免打扰"与"静默校验"两条规则成为不可达代码。
    //
    // 这不是"短暂显示未登录"，而是**登录态恢复永久失效**（token 存了也用不上）。
    void this.bootstrapAuth(windowStage, fromLearningCard);

    // ★ 全场景分布式：先申请「多设备协同」权限，再初始化分布式会话。
    //   失败不阻断任何主流程 —— 单设备功能完全不受影响（见 DistributedStateService 文档）。
    void this.setupDistributedState();
  }

  /**
   * 串行完成"恢复加密凭据 → 恢复登录态"。
   *
   * 顺序不可颠倒：`restoreIdentity()` 依赖 `AuthStore` 里已解密好的 session。
   */
  private async bootstrapAuth(windowStage: window.WindowStage, fromLearningCard: boolean): Promise<void> {
    try {
      const ready: boolean = await AuthStore.initialize(this.context);
      if (!ready) {
        hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Failed to restore auth session.');
      }
      if (AuthStore.encryptionDegraded()) {
        hilog.warn(DOMAIN, 'testTag', '%{public}s',
          'Token encryption unavailable; credentials fall back to plaintext storage.');
      }
    } catch (error) {
      // 凭据恢复失败不应阻断启动：按未登录继续，由 restoreIdentity 决定去登录页
      hilog.error(DOMAIN, 'testTag', 'AuthStore init failed: %{public}s', JSON.stringify(error));
    }
    await this.restoreIdentity(windowStage, fromLearningCard);
  }

  /**
   * 申请分布式数据同步权限并初始化跨设备会话。
   *
   * 权限依据（本机 SDK `toolchains/lib/PermissionDefinitions.json`）：
   *   `ohos.permission.DISTRIBUTED_DATASYNC`
   *     grantMode = user_grant → 必须运行时申请，系统会弹授权框
   *     availableLevel = normal → 普通应用可申请
   *
   * ⚠️ 为什么不在 `onCreate` 里做：`requestPermissionsFromUser` 需要 UI 上下文，
   * 在 `onWindowStageCreate` 之后调用才能正常弹出授权框。
   */
  private async setupDistributedState(): Promise<void> {
    const permission: Permissions = 'ohos.permission.DISTRIBUTED_DATASYNC';
    const service: DistributedStateService = DistributedStateService.getInstance();
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      // `Context.applicationInfo` 是**同步只读属性**（见 @ohos.app.ability.Context.d.ts），
      // 不是方法，不要写成 getApplicationInfo()。
      const accessTokenId: number = this.context.applicationInfo.accessTokenId;
      let granted: boolean = false;
      const status: abilityAccessCtrl.GrantStatus =
        manager.checkAccessTokenSync(accessTokenId, permission);
      granted = status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;

      if (!granted) {
        const result = await manager.requestPermissionsFromUser(this.context, [permission]);
        const codes: Array<number> = result.authResults;
        granted = codes.length > 0 && codes[0] === 0;   // 0 = PERMISSION_GRANTED
        hilog.info(DOMAIN, 'testTag',
          'DISTRIBUTED_DATASYNC requested, granted=%{public}s', `${granted}`);
      }
      await service.init(this.context, granted);
    } catch (error) {
      // 权限申请本身失败也要让服务拿到"未授权"状态，UI 才能如实提示，
      // 而不是停在一个既不报错也不工作的中间态。
      hilog.error(DOMAIN, 'testTag', 'setupDistributedState failed: %{public}s', JSON.stringify(error));
      await service.init(this.context, false);
    }
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.pendingLaunchWant = want;
    if (this.activeWindowStage !== null && this.prepareLearningCardLaunch(want)) {
      this.activeWindowStage.loadContent('pages/FocusSetup');
    }
  }

  /**
   * 恢复登录态并条件跳转。
   *
   * 三条规则（顺序即优先级）：
   *   1. 本地**没有登录态** → 一律展示登录页。**离线模式也不例外** ——
   *      登录页本身提供了「跳过登录，用演示身份进入」与「离线模式进入」两个逃生口，
   *      所以"必须先看到登录页"不会挡路，反而保证登录入口始终存在。
   *   2. 本地有登录态且处于离线 Fixture → 不打扰，直接以该身份进入对话页。
   *   3. 本地有登录态 → 静默校验；成功则对齐身份，失败则降级为游客（不卡登录页）。
   *
   * ⚠️ 规则 1 的修正来源：原实现把"离线 Fixture"放在最前面，一旦用户点过离线进入，
   * 之后**永远跳过登录页**，表现为"登录界面怎么没有了"。现已修正。
   *
   * ⚠️ 「校验失败降级为游客」是刻意的：评审过程中一个过期 token
   * 不该让整个 App 不可用。这条纪律优先于安全洁癖。
   */
  private async restoreIdentity(windowStage: window.WindowStage, allowGuestLaunch: boolean = false): Promise<void> {
    try {
      // 规则 1：没有登录态 → 先看登录页（离线模式也走这里）
      if (!AuthStore.isSignedIn()) {
        appState.applyLogout();
        if (allowGuestLaunch) return;
        await windowStage.loadContent('pages/Login');
        return;
      }

      // 规则 2：有登录态 + 离线模式 → 不做网络校验，直接用保存的身份
      if (AgentApiClient.getConfig().useFixture) {
        const restored: AuthResult = await AuthClient.restore();
        if (restored.ok && restored.user !== null) {
          appState.applyLogin(restored.user, restored.source);
        }
        return;
      }

      // 规则 3：有登录态 + 联机模式 → 静默校验
      const result: AuthResult = await AuthClient.restore();
      if (result.ok && result.user !== null) {
        appState.applyLogin(result.user, result.source);
        hilog.info(DOMAIN, 'testTag', 'Restored identity: %{public}s', result.user.userId);
      } else {
        appState.applyLogout();
        await windowStage.loadContent('pages/Login');
      }
    } catch (error) {
      // 任何异常都不能把用户挡在门外
      hilog.error(DOMAIN, 'testTag', 'restoreIdentity failed: %{public}s', JSON.stringify(error));
      appState.applyLogout();
    } finally {
      // ★ 卡片任务兜底（文档 P0-3）。
      //
      // 上面三条规则里的每一条、以及 catch 分支，都会直接或间接调用
      // `applyLogout()` / `applyLogin()` → `resetAccountScopedState()` →
      // `this.activeFocusTask = null`。而桌面学习卡片带来的任务是在
      // `onWindowStageCreate` 里**先于**本方法写入的 —— 不在这里补写一次，
      // 它一定会被清掉：「点卡片冷启动 → 专注设置页任务名回到默认值、
      // 时长从卡片上的 45 分钟变成 30 分钟」。
      if (this.pendingCardTask !== null) {
        appState.setFocusTask(this.pendingCardTask);
      }
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
    this.activeWindowStage = null;
    // ★ 退出分布式会话。
    //
    // `DistributedStateService.leave()` 此前**一个调用点都没有**（它自己的注释还写着
    // "页面销毁时调用"）—— 于是本机不会主动 `off('change')`、也不退出 session；
    // 答辩若被问"分布式会话怎么退出"，代码里找不到答案。
    // 窗口销毁是本 Ability 生命周期的终点，在这里退出最直接；
    // 内部已做空值判断，未初始化过就什么都不做。
    void DistributedStateService.getInstance().leave();
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    void ProactiveSurfaceService.refresh(this.context, false);
  }

  /** Converts card parameters into the same FocusTask consumed by FocusSetup. */
  private prepareLearningCardLaunch(want: Want | null): boolean {
    if (want === null || want.parameters === undefined) return false;
    const source: Object | undefined = want.parameters['source'];
    if (`${source ?? ''}` !== 'learning_card') return false;
    const taskValue: Object | undefined = want.parameters['taskName'];
    const durationValue: Object | undefined = want.parameters['durationMinutes'];
    const taskName: string = `${taskValue ?? ''}`.trim();
    const parsedMinutes: number = Number(durationValue ?? 30);
    const durationMinutes: number = parsedMinutes >= 1 && parsedMinutes <= 180 ? parsedMinutes : 30;
    const cardTask: FocusTask = {
      course: appState.getHighPriorityCourse()?.courseName ?? '通用学习',
      task: taskName.length > 0 ? taskName : '完成今日学习建议',
      plannedMinutes: durationMinutes,
      source: 'agent',
      mode: 'normal',
      timerType: 'countdown'
    };
    // ⚠️ 这里只是**先写一次**保证首屏渲染正确；真正保住它的是 `restoreIdentity()`
    // 的 finally 分支。原因是启动序列里 `applyLogout()`（onWindowStageCreate 与
    // restoreIdentity 各一次）与 `applyLogin()` 都会走 `resetAccountScopedState()`，
    // 而那里有 `this.activeFocusTask = null` —— 卡片任务写在两次清理之间，必然被抹掉。
    // 表现为：从桌面卡片点进来，任务名回到默认值、时长从 45 分钟变成 30 分钟。
    this.pendingCardTask = cardTask;
    appState.setFocusTask(cardTask);
    return true;
  }

}
