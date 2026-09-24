/** DTOs mirrored from the authoritative Agent backend contract. */
export const API_CONTRACT_VERSION: string = 'api-contract-v0.3';

export type WorkflowStatus = 'running' | 'completed' | 'failed' | 'fallback' | 'error';
export type PlanTaskStatus = 'pending' | 'in_progress' | 'completed';

/* ==================== 知识库（api-contract-v0.3 新增） ==================== */

/**
 * 文档处理状态。
 * `failed` 是**真实可达**的状态（如 PDF 第一期不支持、编码错误），
 * 界面必须展示失败原因，不能假装成功。
 */
export type KnowledgeDocumentStatus = 'ready' | 'failed';

/** 知识库（按课程组织）。`userId` 表明它是个人资料，必须按用户隔离。 */
export interface KnowledgeBase {
  kbId: string;
  userId: string;
  courseName: string;
  name: string;
  description?: string;
  documentCount?: number;
  chunkCount?: number;
  knowledgePoints?: string[];
  createdAt?: string;
  updatedAt?: string;
}

/** 知识库详情：在基础字段上附带文档列表。 */
export interface KnowledgeBaseDetail extends KnowledgeBase {
  documents?: KnowledgeDocument[];
}

export interface KnowledgeDocument {
  documentId: string;
  kbId: string;
  userId: string;
  fileName: string;
  mimeType?: string;
  sizeBytes?: number;
  status: KnowledgeDocumentStatus;
  /** 失败时的可读原因；成功时为空字符串。 */
  statusMessage?: string;
  charCount?: number;
  chunkCount?: number;
  knowledgePoints?: string[];
  errorPointCandidates?: string[];
  uploadedAt?: string;
  parsedAt?: string;
}

/**
 * 检索命中的原文片段。
 * `headingPath` 是引用标注的关键 —— 有它才能显示「第3章 > 3.2.3 后序遍历」，
 * 而不只是「某个文件里」。
 */
export interface KnowledgeChunkHit {
  chunkId: string;
  documentId: string;
  fileName?: string;
  headingPath?: string;
  text: string;
  knowledgePoints?: string[];
  score: number;
}

export interface KnowledgeBaseListResponse {
  knowledgeBases: KnowledgeBase[];
  total: number;
}

export interface KnowledgeDocumentListResponse {
  kbId: string;
  documents: KnowledgeDocument[];
  total: number;
}

export interface KnowledgeSearchRequest {
  query: string;
  topK?: number;
  knowledgePointId?: string;
  userId?: string;
}

export interface KnowledgeSearchResponse {
  kbId: string;
  query: string;
  hits: KnowledgeChunkHit[];
  totalScanned: number;
  /**
   * **实际**使用的检索方式（后端诚实标注）：
   *   · `keyword+tag`                 —— 纯关键词 + 标签 + 标题（未配置 Key，或向量调用失败）
   *   · `hybrid:semantic+keyword+tag` —— embedding 语义分与关键词分加权融合
   *   · `vector`                      —— 预留：将来若改为纯向量检索
   * 可直接显示给用户/评委，**不要自行改写这两个字符串**，否则会失去"诚实标注"的意义。
   */
  retrievalMode: string;
  /** 是否具备语义检索能力（即后端是否配置了 DASHSCOPE_API_KEY）。注意是"能力"而非"本次用上了"。 */
  semanticAvailable: boolean;
  /** 本次语义分权重（0–1）。为 0 表示语义未参与打分。 */
  semanticWeight: number;
}

export interface KnowledgeBaseCreateRequest {
  courseName: string;
  name: string;
  description?: string;
  userId?: string;
}

export interface KnowledgeDocumentUploadRequest {
  fileName: string;
  contentBase64: string;
  mimeType?: string;
  sizeBytes?: number;
  userId?: string;
}

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

export interface WorkflowRunResponse {
  sessionId: string;
  traceId: string;
  status: WorkflowStatus;
  currentStep: string;
  currentAgent: string;
  stateVersion: number;
  finalAction: string | null;
  state?: Record<string, Object>;
}

export interface WorkflowRunRequest {
  submissionId?: string;
  answers?: ExerciseAnswer[];
}

export interface DecisionFactor {
  name: string;
  value: number;
  weight: number;
  contribution: number;
}

export interface ProactiveContext {
  now: string;
  location?: string;
  foreground: boolean;
  lastStudyAt?: string;
  focusSessionActive: boolean;
  masteryScore?: number;
  errorIntensity?: number;
  daysLeft?: number;
  importance?: number;
  pendingTasks?: PendingTaskSignal[];
}

export interface PendingTaskSignal {
  taskId?: string;
  title?: string;
  status?: string;
  started?: boolean;
  daysLeft?: number;
}

export interface ProactiveRequest {
  userId: string;
  context: ProactiveContext;
}

export interface ProactiveActionPreset {
  taskId?: string;
  durationMinutes?: number;
}

export interface ProactiveAction {
  type: string;
  targetPage: string;
  preset: ProactiveActionPreset;
}

export interface ProactiveCardData {
  taskName?: string;
  durationMinutes?: number;
  examCountdownDays?: number;
  hint?: string;
}

export interface ProactiveResponse {
  userId?: string;
  shouldNotify: boolean;
  channel: 'reminder' | 'silent';
  title: string;
  body: string;
  action: ProactiveAction;
  contextTags: string[];
  reason: string;
  factors: DecisionFactor[];
  cardData: ProactiveCardData;
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
  factors?: DecisionFactor[];
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

export interface ExerciseQuery {
  knowledgePointId?: string;
  difficulty?: string;
  count?: number;
  excludeExerciseIds?: string[];
  /**
   * 题库覆盖不到该知识点时，是否允许服务端**现场让大模型出题**。
   *
   * 只应在「错题诊断 → 做同类专项题」这条路径上置 true：那时知识点来自诊断结果，
   * 可能不在固定题库的 6 个知识点里。默认不传 —— 演示路径行为与之前完全一致，
   * 也不会多付一次模型调用。
   */
  generate?: boolean;
}

export interface ExerciseAnswer {
  exerciseId: string;
  answer: string;
}

export interface ExerciseSubmission {
  userId?: string;
  sessionId?: string;
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
  userId?: string;
  submissionId?: string;
  assessment: AssessmentResult;
  masteryUpdate: MasteryUpdate | null;
  needReplan: boolean;
  plan?: LearningPlan;
  planDiff?: PlanDiff;
  traceId?: string;
  evidenceIds?: string[];
  replanDecision?: Record<string, Object>;
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

/* ================================================================
 * 学习搭子匹配（POST /api/v1/agent/partner-match）
 *
 * 五因子确定性算分，满分 100：
 *   目标一致 goal 30 / 时间重叠 timeOverlap 30 / 知识互补 knowledgeComplement 20
 *   / 基础匹配 basicMatch 10 / 稳定性 stability 10
 * 与后端 app/agent/partner_match.py:score_partner 逐项对应。
 * ================================================================ */

/** 单个候选人的五因子明细。 */
export interface PartnerMatchFactors {
  goal: number;
  timeOverlap: number;
  knowledgeComplement: number;
  basicMatch: number;
  stability: number;
  /** 两人空闲时间段的实际重叠分钟数（展示"为什么是 20 分"时要用）。 */
  overlapMinutes: number;
}

/** 候选人完整资料（结构与 mock_candidates.json 一致）。 */
export interface PartnerCandidateProfile {
  userId: string;
  basicInfo?: PartnerCandidateBasicInfo;
  learningGoal?: PartnerCandidateGoal;
  time?: PartnerCandidateTime;
  knowledge?: PartnerCandidateKnowledge;
}

export interface PartnerCandidateBasicInfo {
  name?: string;
  grade?: string;
  major?: string;
}

export interface PartnerCandidateGoal {
  course?: string;
  goal?: string;
}

export interface PartnerCandidateTime {
  freeTime?: string[];
}

export interface PartnerCandidateKnowledge {
  weakness?: string[];
  strength?: string[];
}

/** 一个候选人的匹配结果。 */
export interface PartnerRankedCandidate {
  candidate: PartnerCandidateProfile;
  score: number;
  factors: PartnerMatchFactors;
}

/** 匹配接口响应。 */
export interface PartnerMatchResponse {
  userId: string;
  /** 最高分候选人；全部为 0 分时为 null。 */
  matchedCandidate: PartnerRankedCandidate | null;
  /** 全部候选人按分数降序。 */
  candidates: PartnerRankedCandidate[];
  generatedAt: string;
  realModeUnavailable: boolean;
}

/** 请求体：可传完整 user 对象，也可只传 userId（后端用 mock_users 兜底）。 */
export interface PartnerMatchRequest {
  userId?: string;
  user?: PartnerCandidateProfile;
  candidates?: PartnerCandidateProfile[];
}
