/* ============================================================
 * AgentModels.ets — 知学Mate 5层Agent工作流数据模型
 * ============================================================
 * 输入层 → 理解层 → 判断层 → 行动层 → 输出层
 * ============================================================ */

/* ==================== 用户 & 课程基础模型 ==================== */

export interface BasicInfo {
  name: string;
  grade: string;
  major: string;
}

export interface LearningGoal {
  course: string;
  goal: string;
}

export interface UserTime {
  freeTime: string[];
}

export interface KnowledgeInfo {
  weakness: string[];
  strength: string[];
}

export interface UserProfile {
  userId: string;
  basicInfo: BasicInfo;
  learningGoal: LearningGoal;
  time: UserTime;
  knowledge: KnowledgeInfo;
}

export interface ExamInfo {
  date: string;
  daysLeft: number;
}

export interface RecentStatus {
  studyHours: number;
  status: string;
}

export interface CourseInfo {
  courseId: string;
  courseName: string;
  exam: ExamInfo;
  priority: string;
  recentStatus: RecentStatus;
}

export interface HomeworkDDL {
  id: string;
  courseName: string;
  title: string;
  dueDate: string;
  daysLeft: number;
  priority: string;
  estimatedMinutes: number;
}

/* ==================== 错题记录模型（兼容旧版） ==================== */

export interface KnowledgeResult {
  name: string;
  confidence: number;
}

export interface WrongQuestionSuggestion {
  studyTag: string;
  task: string;
}

export interface WrongQuestionInput {
  image: string;
  myAnswer: string;
  correctAnswer: string;
}

export interface AIAnalysis {
  course: string;
  knowledge: KnowledgeResult[];
  wrongType: string;
  reason: string;
  Tag: string[];
  suggestion: WrongQuestionSuggestion[];
}

export interface WrongQuestionRecord {
  questionId: string;
  userId: string;
  input: WrongQuestionInput;
  AIAnalysis: AIAnalysis;
}

/* ==================== 第1层：输入层 (Input Layer) ==================== */

/** 用户上传的错题图片信息 */
export interface WrongQuestionImage {
  imageUri: string;        // 图片URI（真实拍照/选图后的路径）
  fileName: string;        // 文件名
  uploadTime: string;      // 上传时间
}

/** 完整的输入层数据：汇集课表、考试、DDL、错题图片、用户目标、空闲时间 */
export interface InputLayerData {
  courses: CourseInfo[];
  homeworkDDLs: HomeworkDDL[];
  wrongQuestionImages: WrongQuestionImage[];
  userGoal: LearningGoal;
  freeTime: string[];
}

/* ==================== 第2层：理解层 (Understanding Layer) ==================== */

/** 错题知识点分析 */
export interface KnowledgeAnalysis {
  course: string;
  knowledgePoints: KnowledgeResult[];
  errorType: string;       // 概念混淆 / 计算错误 / 审题不清 / 知识盲区
  rootCause: string;       // 根本原因分析
  difficultyLevel: string; // 简单 / 中等 / 困难
}

/** 学习目标理解 */
export interface GoalUnderstanding {
  targetCourse: string;
  targetScore: string;
  currentLevel: string;    // Agent 评估的当前水平
  gap: string;             // 差距描述
}

/** 理解层完整输出 */
export interface UnderstandingLayerData {
  courseAnalysis: Map<string, KnowledgeAnalysis>;  // 按课程分组的错题分析
  examUrgency: Map<string, number>;                 // 课程 → 紧迫度评分
  errorPatternSummary: string;                       // 错误模式总结
  goalUnderstanding: GoalUnderstanding;
}

/* ==================== 第3层：判断层 (Judgment Layer) ==================== */

/** 学习任务优先级判断 */
export interface TaskPriority {
  courseName: string;
  task: string;
  priorityScore: number;   // 0-100
  urgencyFactors: string[];
  suggestedDuration: number; // 分钟
}

/** 知识薄弱点判断 */
export interface WeaknessJudgment {
  knowledgePoint: string;
  weaknessLevel: string;   // 严重 / 一般 / 轻微
  missedCount: number;     // 错题中出现次数
  relatedExamWeight: number; // 考试占比预估
}

/** 搭子匹配可行性判断 */
export interface MatchFeasibility {
  canMatch: boolean;
  availableCandidates: number;
  bestMatchFactor: string;  // 最有利的匹配因子
}

/** 判断层完整输出 */
export interface JudgmentLayerData {
  optimalTask: TaskPriority;
  allTasks: TaskPriority[];
  weaknessPoints: WeaknessJudgment[];
  matchFeasibility: MatchFeasibility;
  recommendedAction: string;  // Agent 推荐的最优行动
}

/* ==================== 第4层：行动层 (Action Layer) ==================== */

export interface StudySuggestion {
  course: string;
  task: string;
  reason: string;
  duration: string;
  priority: string;
  priorityScore: number;
}

export interface WrongAnalysisResult {
  course: string;
  knowledge: string[];
  wrongType: string;
  reason: string;
  suggestions: string[];
  tags: string[];
  imageUri: string;        // 关联的原始图片URI
}

export interface TimeRange {
  start: number;
  end: number;
}

export interface OverlapResult {
  score: number;
  start: string | null;
  end: string | null;
  duration: number;
}

export interface PartnerMatch {
  matchName: string;
  userId: string;
  score: number;
  reasons: string[];
  studyTime: string | null;
  duration: number;
  matchFactors: MatchFactor[];
}

export interface MatchFactor {
  label: string;
  score: string;
  match: boolean;
  detail: string;
}

/* ==================== 第5层：输出层 (Output Layer) ==================== */

/** 今日学习卡 */
export interface DailyLearningCard {
  date: string;
  suggestion: StudySuggestion;
  urgentDDLCount: number;
  examDaysLeft: number;
  highPriorityCourse: string;
}

/** 错题诊断卡 */
export interface WrongQuestionDiagnosticCard {
  totalAnalyzed: number;
  latestAnalysis: WrongAnalysisResult | null;
  weaknessTags: string[];
  strengthTags: string[];
  summary: string;
}

/** 学习搭子卡 */
export interface PartnerCard {
  partner: PartnerMatch | null;
  matchFactors: MatchFactor[];
  suggestion: string;
}

/** 协同学习计划 */
export interface CollaborativePlan {
  totalMinutes: number;
  partnerName: string;
  phases: StudyPhase[];
  commonTopics: string[];
  startTime: string;
}

export interface StudyPhase {
  time: string;
  icon: string;
  title: string;
  desc: string;
}

/** 学习复盘 & 徽章 */
export interface LearningBadge {
  name: string;
  icon: string;
  description: string;
}

export interface LearningReview {
  totalMinutes: number;
  completedTasks: string[];
  knowledgeReviewed: string[];
  partnerName: string | null;
  badges: LearningBadge[];
  strengthsGained: string[];
  nextSteps: string[];
}

/* ==================== 涓撴敞妯″紡 ==================== */

export type FocusSource = 'agent' | 'manual' | 'course' | 'collaborative';
export type FocusMode = 'normal' | 'strict';
export type FocusTimerType = 'countdown' | 'stopwatch';
export type FocusSelfAssessment = 'completed' | 'partial' | 'not_completed';
export type FocusSessionStatus = 'completed' | 'not_completed' | 'interrupted';

export interface FocusTask {
  course: string;
  task: string;
  plannedMinutes: number;
  source: FocusSource;
  mode: FocusMode;
  timerType?: FocusTimerType;
  planTaskId?: string;
}

export interface FocusSession {
  taskId: string;
  planTaskId?: string;
  course: string;
  task: string;
  plannedMinutes: number;
  actualMinutes: number;
  pauseCount: number;
  interruptionCount: number;
  completionRate: number;
  selfAssessment: FocusSelfAssessment;
  timerType: FocusTimerType;
  status: FocusSessionStatus;
  endedAt: string;
}

export interface AgentFeedback {
  level: 'adjust' | 'continue' | 'advance';
  feedback: string;
  nextSuggestion: string;
}

export interface FocusSummary {
  todayMinutes: number;
  completionRate: number;
  streakDays: number;
  courseMinutes: Map<string, number>;
  recentSessions: FocusSession[];
}

/* ==================== 计划 Agent ==================== */

export type PlanTaskStatus = 'todo' | 'in_progress' | 'completed' | 'partial' | 'deferred';
export type PlanTaskType = 'learn' | 'practice' | 'review' | 'test' | 'assignment';

/** Agent 生成的可执行学习任务 */
export interface LearningPlanTask {
  id: string;
  course: string;
  title: string;
  knowledgePoint: string;
  type: PlanTaskType;
  dateLabel: string;
  plannedMinutes: number;
  priorityScore: number;
  priorityLabel: string;
  reason: string;
  completionCriteria: string;
  steps: string[];
  status: PlanTaskStatus;
  source: 'agent' | 'ddl' | 'wrong_question' | 'focus_feedback' | 'partner_match';
  canCollaborate: boolean;
}

/** 让用户看得懂的 Agent 判断过程 */
export interface AgentDecisionTrace {
  inputSummary: string;
  urgencyReason: string;
  weaknessReason: string;
  timeReason: string;
  recommendation: string;
  updatedAt: string;
}

export interface WeeklyLearningPlan {
  weekLabel: string;
  tasks: LearningPlanTask[];
  decisionTrace: AgentDecisionTrace;
  adjustmentMessage: string;
}

/* ==================== 导航 & 工作流状态 ==================== */

/** 当前所处的Agent工作流阶段 */
export type WorkflowStage = 'idle' | 'input' | 'understanding' | 'judgment' | 'action' | 'output';

/** 导航意图：用户在完成某页面后想去哪里 */
export type NavigationIntent =
  | 'back_to_hub'
  | 'analyze_wrong_question'
  | 'find_partner'
  | 'view_study_plan'
  | 'view_review'
  | 'view_courses'
  | 'view_tags';

/* ==================== 工作流上下文 ==================== */

export interface WorkflowContext {
  currentStage: WorkflowStage;
  lastAction: string;
  lastActionTime: string;
  completedStages: WorkflowStage[];
  pendingActions: NavigationIntent[];
}
