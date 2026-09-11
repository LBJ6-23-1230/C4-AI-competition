import { AgentApiClient } from '../api/AgentApiClient';
import { ExerciseQuery, ExerciseSetResponse, ExerciseSubmission, ExerciseSubmissionResult, LearningPlan, PlanDiff } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { ClientCache } from '../cache/ClientCache';

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

  async load(setId: string, forceRefresh: boolean = false,
    query?: ExerciseQuery): Promise<ExerciseSetResponse | null> {
    this.errorMessage = '';
    if (!forceRefresh) {
      const cached: ExerciseSetResponse | null = ClientCache.getExerciseSet();
      if (cached !== null && cached.setId === setId) {
        return cached;
      }
    } else {
      ClientCache.invalidateExerciseSet();
    }
    const result = await AgentApiClient.getExerciseSet(setId, query);
    if (result.ok) {
      ClientCache.cacheExerciseSet(result.data);
      return result.data;
    }
    this.errorMessage = (result as ApiFailure).error.message;
    return null;
  }

  async submit(setId: string, submission: ExerciseSubmission): Promise<ExerciseSubmissionResult | null> {
    this.errorMessage = '';
    this.warningMessage = '';
    const result = await AgentApiClient.submitExercise(setId, submission);
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
      return submissionResult;
    }
    this.errorMessage = (result as ApiFailure).error.message;
    return null;
  }
}
