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

  static cacheProfile(value: ProfileResponse): void { ClientCache.profile = value; }
  static getProfile(): ProfileResponse | null { return ClientCache.profile; }
  static invalidateProfile(): void { ClientCache.profile = null; }

  static cacheCurrentPlan(value: LearningPlan): void { ClientCache.currentPlan = value; }
  static getCurrentPlan(): LearningPlan | null { return ClientCache.currentPlan; }

  static cacheWorkflow(value: WorkflowResponse): void { ClientCache.workflow = value; }
  static getWorkflow(): WorkflowResponse | null { return ClientCache.workflow; }

  static cacheWorkflowStatus(value: WorkflowStatusResponse): void { ClientCache.workflowStatus = value; }
  static getWorkflowStatus(): WorkflowStatusResponse | null { return ClientCache.workflowStatus; }

  static cacheExerciseSet(value: ExerciseSetResponse): void { ClientCache.exerciseSet = value; }
  static getExerciseSet(): ExerciseSetResponse | null { return ClientCache.exerciseSet; }

  static cacheAssessment(value: ExerciseSubmissionResult): void { ClientCache.latestAssessment = value; }
  static getAssessment(): ExerciseSubmissionResult | null { return ClientCache.latestAssessment; }

  static cachePlanDiff(value: PlanDiff): void { ClientCache.planDiff = value; }
  static getPlanDiff(): PlanDiff | null { return ClientCache.planDiff; }

  static cacheTrace(value: TraceResponse): void { ClientCache.trace = value; }
  static getTrace(): TraceResponse | null { return ClientCache.trace; }

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
