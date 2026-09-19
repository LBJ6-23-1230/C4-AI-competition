import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
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
import { ProactiveSurfaceService } from '../services/ProactiveSurfaceService';
import { ProactiveSettingsStore } from '../services/ProactiveSettingsStore';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private activeWindowStage: window.WindowStage | null = null;
  private pendingLaunchWant: Want | null = null;

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

    if (!ApiEnvironmentStore.restore(this.context)) {
      hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Failed to restore API environment, using defaults.');
    }
    if (!FixtureDemoStateStore.initialize(this.context)) {
      hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Failed to restore fixture demo state.');
    }
    if (!WorkflowSessionStore.restore(this.context)) {
      hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Failed to restore workflow session.');
    }
    if (!AuthStore.initialize(this.context)) {
      hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Failed to restore auth session.');
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

    void this.restoreIdentity(windowStage, fromLearningCard);
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
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
    this.activeWindowStage = null;
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
    appState.setFocusTask({
      course: appState.getHighPriorityCourse().courseName,
      task: taskName.length > 0 ? taskName : '完成今日学习建议',
      plannedMinutes: durationMinutes,
      source: 'agent',
      mode: 'normal',
      timerType: 'countdown'
    });
    return true;
  }

}
