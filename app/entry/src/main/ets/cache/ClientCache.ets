import {
  ExerciseSetResponse,
  ExerciseSubmissionResult,
  LearningPlan,
  PlanDiff,
  ProfileResponse,
  TraceResponse,
  WorkflowResponse,
  WorkflowStatusResponse
} from '../api/ApiModels';

/**
 * Short-lived UI cache for server responses.
 *
 * This class never creates, scores, or changes business data. It only keeps
 * the latest DTO returned by AgentApiClient so several pages can read one
 * consistent response during a session.
 */
export class ClientCache {
  private static profile: ProfileResponse | null = null;
  private static currentPlan: LearningPlan | null = null;
  private static workflow: WorkflowResponse | null = null;
  private static workflowStatus: WorkflowStatusResponse | null = null;
  private static exerciseSet: ExerciseSetResponse | null = null;
  private static latestAssessment: ExerciseSubmissionResult | null = null;
  private static planDiff: PlanDiff | null = null;
  private static trace: TraceResponse | null = null;

  /**
   * 本缓存的归属身份。
   *
   * ⚠️ 这个类读不到登录态，**必须**由 `AppState.applyLogin` / `applyLogout`
   * 统一调用 `bindIdentity()` 来维护，页面不要自己改。
   *
   * 修复的缺陷：原实现没有任何身份维度，而唯一的清除时机只在「我的 → 退出/切换」
   * 与「接口环境」里。于是「游客逛一圈 → 返回登录 → 登录账号」这条路径下，
   * 账号读到的全是游客（demo-user）的画像 / 计划 / 工作流 / trace，
   * 而 `isCached` 只写不渲染 —— **用户看到演示数据却没有任何提示**，
   * 表现为"账号登录和游客登录进去看到的不一样"。
   */
  private static ownerUserId: string = '';

  /**
   * 启动时 `WorkflowSessionStore.restore()` 读回、但当时身份尚未确定的工作流。
   *
   * 时序原因：`EntryAbility.onCreate` 里 restore 发生在 `AuthStore.initialize()`
   * 之前，那一刻不知道用户是谁。所以先暂存，等 `bindIdentity()` 认出身份再采纳，
   * 避免"账号沿用上一个游客的工作流"（提交练习时会 404）。
   */
  private static pendingWorkflowOwner: string = '';
  private static pendingWorkflow: WorkflowResponse | null = null;

  /**
   * 身份切换时调用。缓存与所属身份不一致则**整体失效**，否则保留。
   *
   * 幂等：同身份重复调用不清缓存（登录态刷新不该把数据抖掉）。
   */
  static bindIdentity(userId: string): void {
    if (ClientCache.ownerUserId !== userId) {
      ClientCache.clearDemoData();
    }
    ClientCache.ownerUserId = userId;
    if (ClientCache.pendingWorkflow !== null && ClientCache.pendingWorkflowOwner === userId) {
      ClientCache.workflow = ClientCache.pendingWorkflow;
      ClientCache.workflowStatus = null;
    }
  }

  /** 暂存启动时读回的工作流；身份已知且匹配时立即生效，否则等 `bindIdentity()`。 */
  static stageRestoredWorkflow(ownerUserId: string, value: WorkflowResponse): void {
    ClientCache.pendingWorkflowOwner = ownerUserId;
    ClientCache.pendingWorkflow = value;
    if (ClientCache.ownerUserId === ownerUserId) {
      ClientCache.workflow = value;
      ClientCache.workflowStatus = null;
    }
  }

  /** 当前缓存归属身份，供断言与排错用。 */
  static currentOwnerUserId(): string {
    return ClientCache.ownerUserId;
  }

  static cacheProfile(value: ProfileResponse): void { ClientCache.profile = value; }
  static getProfile(): ProfileResponse | null { return ClientCache.profile; }
  static invalidateProfile(): void { ClientCache.profile = null; }

  static cacheCurrentPlan(value: LearningPlan): void { ClientCache.currentPlan = value; }
  static getCurrentPlan(): LearningPlan | null { return ClientCache.currentPlan; }
  static invalidateCurrentPlan(): void { ClientCache.currentPlan = null; }

  static cacheWorkflow(value: WorkflowResponse): void { ClientCache.workflow = value; }
  static getWorkflow(): WorkflowResponse | null { return ClientCache.workflow; }
  static invalidateWorkflow(): void {
    ClientCache.workflow = null;
    ClientCache.workflowStatus = null;
  }

  static cacheWorkflowStatus(value: WorkflowStatusResponse): void { ClientCache.workflowStatus = value; }
  static getWorkflowStatus(): WorkflowStatusResponse | null { return ClientCache.workflowStatus; }
  static invalidateWorkflowStatus(): void { ClientCache.workflowStatus = null; }

  static cacheExerciseSet(value: ExerciseSetResponse): void { ClientCache.exerciseSet = value; }
  static getExerciseSet(): ExerciseSetResponse | null { return ClientCache.exerciseSet; }
  static invalidateExerciseSet(): void { ClientCache.exerciseSet = null; }

  static cacheAssessment(value: ExerciseSubmissionResult): void { ClientCache.latestAssessment = value; }
  static getAssessment(): ExerciseSubmissionResult | null { return ClientCache.latestAssessment; }

  static cachePlanDiff(value: PlanDiff): void { ClientCache.planDiff = value; }
  static getPlanDiff(): PlanDiff | null { return ClientCache.planDiff; }

  static cacheTrace(value: TraceResponse): void { ClientCache.trace = value; }
  static getTrace(): TraceResponse | null { return ClientCache.trace; }
  static invalidateTrace(): void { ClientCache.trace = null; }

  /** Call after POST /api/v1/demo/reset succeeds, then re-fetch fresh DTOs. */
  static clearDemoData(): void {
    ClientCache.profile = null;
    ClientCache.currentPlan = null;
    ClientCache.workflow = null;
    ClientCache.workflowStatus = null;
    ClientCache.exerciseSet = null;
    ClientCache.latestAssessment = null;
    ClientCache.planDiff = null;
    ClientCache.trace = null;
  }
}
