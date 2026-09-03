/** DTOs mirrored from contracts/openapi.json (api-contract-v0.2). */
export const API_CONTRACT_VERSION: string = 'api-contract-v0.2';

export type WorkflowStatus = 'running' | 'completed' | 'failed' | 'fallback';
export type PlanTaskStatus = 'pending' | 'in_progress' | 'completed';

export interface Evidence {
  id: string;
  sourceType: string;
  sourceId: string;
  knowledgePointId: string;
  metric: string;
  value: Object;
  timestamp: string;
  reliability: number;
}

export interface KnowledgeMastery {
  knowledgePointId: string;
  knowledgePointName: string;
  masteryScore: number;
  confidence: number;
  lastUpdated: string;
}

export interface MasteryHistory {
  oldScore: number;
  newScore: number;
  evidenceIds: string[];
  source: string;
  timestamp: string;
}

export interface LearnerProfile {
  userId: string;
  goal: string;
  examDate: string | null;
  freeTimeSlots: string[];
  profileVersion: number;
  mastery: KnowledgeMastery[];
}

export interface ProfileResponse {
  profileVersion: number;
  profile?: LearnerProfile;
  mastery: KnowledgeMastery[];
  history: MasteryHistory[];
  evidence: Evidence[];
}

export interface WorkflowCreateRequest {
  goal: string;
  sessionId?: string;
  userId?: string;
  maxSteps?: number;
}

export interface WorkflowResponse {
  sessionId: string;
  traceId: string;
  status: WorkflowStatus;
  currentStep: string;
  nextAction: string;
}

export interface WorkflowStatusResponse {
  status: WorkflowStatus;
  currentAgent: string | null;
  stateVersion: number;
  finalAction: string | null;
}

export interface PlanTask {
  taskId: string;
  knowledgePointId: string;
  knowledgePointName: string;
  durationMinutes: number;
  status: PlanTaskStatus;
  priority?: string;
}

export interface LearningPlan {
  planId: string | null;
  version: number;
  tasks: PlanTask[];
  reason?: string;
  generatedFromProfileVersion: number;
}

export interface Exercise {
  exerciseId: string;
  knowledgePointId: string;
  knowledgePointName: string;
  difficulty?: string;
  stem: string;
  options: string[];
  source?: string;
}

export interface ExerciseSetResponse {
  setId: string;
  exercises: Exercise[];
}

export interface ExerciseAnswer {
  exerciseId: string;
  answer: string;
}

export interface ExerciseSubmission {
  idempotencyKey: string;
  answers: ExerciseAnswer[];
}

export interface AssessmentResult {
  score: number;
  perKnowledgeAccuracy: Record<string, number>;
  errorTypes: string[];
  oldMastery: number;
  suggestedNewMastery: number;
}

export interface MasteryUpdate {
  knowledgePointId: string;
  oldScore: number;
  newScore: number;
}

export interface PlanTaskChange {
  taskId: string;
  knowledgePointId?: string;
  durationMinutes?: number;
  change?: string;
}

export interface PlanDiff {
  planId?: string;
  oldVersion: number;
  newVersion: number;
  changedTasks: PlanTaskChange[];
  adjustmentReason: string;
  triggerEvidence: string[];
}

export interface ExerciseSubmissionResult {
  assessment: AssessmentResult;
  masteryUpdate: MasteryUpdate | null;
  needReplan: boolean;
  plan?: LearningPlan;
  planDiff?: PlanDiff;
}

export interface TraceEvent {
  agent: string;
  toolCalls: string[];
  inputSummary: string;
  outputSummary: string;
  evidenceIds: string[];
  stateVersion: number;
  timestamp: string;
  status: string;
}

export interface TraceResponse {
  traceId: string;
  events: TraceEvent[];
}

export interface DemoResetResponse {
  status: 'reset';
  userId: string;
  profile: LearnerProfile | null;
  plan: LearningPlan | null;
  traceId: string;
}
