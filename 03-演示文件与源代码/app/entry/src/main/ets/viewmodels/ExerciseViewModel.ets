import { AgentApiClient } from '../api/AgentApiClient';
import { ApiDefaults } from '../api/ApiDefaults';
import { ExerciseQuery, ExerciseSetResponse, ExerciseSubmission, ExerciseSubmissionResult, LearningPlan, PlanDiff, WorkflowResponse, WorkflowRunResponse, WorkflowStatusResponse } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { ClientCache } from '../cache/ClientCache';
import { appState } from '../data/AppState';

/**
 * Prepares the exercise flow for the page. Scores and mastery are always
 * returned by the API/fixture; this class does not calculate them.
 */
export class ExerciseViewModel {
  private errorMessage: string = '';
  private warningMessage: string = '';

  getErrorMessage(): string {
    return this.errorMessage;
  }

  getWarningMessage(): string {
    return this.warningMessage;
  }

  /**
   * 缓存里的题集是否就是本次要的题集。
   *
   * ⚠️ 不能只比 `setId`。同一个 `setId` 配上不同的 `knowledgePointId`
   * 会返回**完全不同的题目**（题库 30 题 / 6 个知识点），只按 setId 命中的话，
   * 「错题诊断 → 做同类专项题」会给回上一次那一套题 —— 也就是用户看到的
   * "永远是那三题"。
   */
  private static matchesQuery(cached: ExerciseSetResponse, query?: ExerciseQuery): boolean {
    if (query === undefined || query.knowledgePointId === undefined
      || query.knowledgePointId.length === 0) {
      return true;   // 没指定知识点：setId 相同即可复用
    }
    const first = cached.exercises.length > 0 ? cached.exercises[0] : undefined;
    if (first === undefined) {
      return false;
    }
    return first.knowledgePointId === query.knowledgePointId;
  }

  async load(setId: string, forceRefresh: boolean = false,
    query?: ExerciseQuery): Promise<ExerciseSetResponse | null> {
    this.errorMessage = '';
    const cached: ExerciseSetResponse | null = ClientCache.getExerciseSet();
    if (!forceRefresh && cached !== null && cached.setId === setId
      && ExerciseViewModel.matchesQuery(cached, query)) {
      return cached;
    }
    const result = await AgentApiClient.getExerciseSet(setId, query);
    if (result.ok) {
      ClientCache.cacheExerciseSet(result.data);
      return result.data;
    }
    this.errorMessage = (result as ApiFailure).error.message;
    if (cached !== null && cached.setId === setId
      && ExerciseViewModel.matchesQuery(cached, query)) {
      this.errorMessage = `${this.errorMessage} 正在显示刚才获取的练习。`;
      return cached;
    }
    return null;
  }

  async submit(setId: string, submission: ExerciseSubmission): Promise<ExerciseSubmissionResult | null> {
    this.errorMessage = '';
    this.warningMessage = '';
    const workflow: WorkflowResponse | null = ClientCache.getWorkflow();
    // 兜底必须是**当前身份**，而不是写死的演示账号。
    //
    // 修复的缺陷：原先兜底 `ApiDefaults.DEMO_USER_ID`，于是真实账号做题时
    // 掌握度被写进演示账号（后端侧同步修了身份解析，两端都改才生效）。
    // 游客/离线态下 `appState.currentUser.userId` 本来就是 demo-user。
    const fallbackUserId: string = appState.currentUser.userId;
    const request: ExerciseSubmission = {
      userId: submission.userId ?? (fallbackUserId.length > 0 ? fallbackUserId : ApiDefaults.DEMO_USER_ID),
      sessionId: submission.sessionId ?? workflow?.sessionId,
      idempotencyKey: submission.idempotencyKey,
      answers: submission.answers
    };
    const result = await AgentApiClient.submitExercise(setId, request);
    if (result.ok) {
      const submissionResult: ExerciseSubmissionResult = result.data;
      let plan: LearningPlan | undefined = submissionResult.plan;
      if (submissionResult.needReplan && plan === undefined) {
        const planResult = await AgentApiClient.getCurrentPlan();
        if (planResult.ok) {
          plan = planResult.data;
          submissionResult.plan = plan;
        } else {
          this.warningMessage = '诊断已完成，但暂时无法读取更新后的学习计划。';
        }
      }
      if (submissionResult.needReplan && submissionResult.planDiff === undefined &&
        plan !== undefined && plan.planId !== null) {
        const diffResult = await AgentApiClient.getPlanDiff(plan.planId);
        if (diffResult.ok) {
          const planDiff: PlanDiff = diffResult.data;
          submissionResult.planDiff = planDiff;
        } else {
          this.warningMessage = '诊断和计划更新已完成，但暂时无法读取计划变更详情。';
        }
      }
      ClientCache.cacheAssessment(submissionResult);
      if (submissionResult.planDiff !== undefined) {
        ClientCache.cachePlanDiff(submissionResult.planDiff);
      }
      if (submissionResult.plan !== undefined) {
        ClientCache.cacheCurrentPlan(submissionResult.plan);
      }
      ClientCache.invalidateProfile();
      ClientCache.invalidateTrace();
      if (workflow !== null && submissionResult.submissionId !== undefined) {
        const workflowResult = await AgentApiClient.runWorkflow(workflow.sessionId,
          { submissionId: submissionResult.submissionId });
        if (workflowResult.ok) {
          const run: WorkflowRunResponse = workflowResult.data;
          const status: WorkflowStatusResponse = {
            status: run.status,
            currentAgent: run.currentAgent,
            stateVersion: run.stateVersion,
            finalAction: run.finalAction
          };
          ClientCache.cacheWorkflowStatus(status);
        } else if (this.warningMessage.length === 0) {
          this.warningMessage = '诊断结果已保存，但 Agent 工作流状态暂时未能同步。';
        }
      }
      return submissionResult;
    }
    this.errorMessage = (result as ApiFailure).error.message;
    return null;
  }
}
