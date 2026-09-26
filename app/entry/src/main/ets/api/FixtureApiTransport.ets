import { util } from '@kit.ArkTS';
import { DecisionFactor, DemoResetResponse, Evidence, Exercise, ExerciseAnswer, ExerciseSetResponse, ExerciseSubmission, ExerciseSubmissionResult, KnowledgeBase, KnowledgeBaseCreateRequest, KnowledgeBaseDetail, KnowledgeBaseListResponse, KnowledgeChunkHit, KnowledgeDocument, KnowledgeDocumentChunk, KnowledgeDocumentDetail, KnowledgeDocumentListResponse, KnowledgeDocumentUploadRequest, KnowledgeMastery, KnowledgeSearchRequest, KnowledgeSearchResponse, LearningPlan, PlanDiff, ProactiveRequest, ProactiveResponse, ProfileResponse, TraceResponse, WorkflowCreateRequest, WorkflowResponse, WorkflowRunRequest, WorkflowRunResponse, WorkflowStatusResponse } from './ApiModels';
import { ApiResult, apiFailure, apiSuccess } from './ApiResult';
import { ApiDefaults } from './ApiDefaults';
import { FixtureDemoStateStore } from './FixtureDemoStateStore';

/** 离线知识库里的一条切片（只用于本地检索打分，不上界面）。 */
interface FixtureChunk {
  chunkId: string;
  documentId: string;
  kbId: string;
  fileName: string;
  headingPath: string;
  text: string;
}

/** Deterministic offline transport mirroring the api-contract-v0.3 payloads. */
export class FixtureApiTransport {
  /**
   * 离线模式下按身份隔离的知识库 / 文档 / 切片。
   *
   * 修复的缺陷：原先 fixture 完全**没有**知识库路由（只有 10 条），
   * 而 `KnowledgeBase` 页也没有 `useFixture` 守卫，于是离线演示点进
   * 「我的知识库」直接报「未找到 fixture 路由」—— 游客和账号都一样进不去。
   * 这里把后端 `app/api/knowledge.py` 的行为按同一份契约复刻一份。
   */
  private static fixtureKbs: KnowledgeBase[] = [];
  private static fixtureDocs: KnowledgeDocument[] = [];
  private static fixtureChunks: FixtureChunk[] = [];
  private static fixtureSeq: number = 0;

  /**
   * 文档详情单次回传的切片上限 —— 与后端 `app/agent/knowledge.py` 的
   * `MAX_CHUNKS_PER_RESPONSE` **必须同值**：否则离线与在线两种模式的
   * "是否截断"标注会对不上，同一份讲义在两种模式下显示不同，演示自相矛盾。
   */
  private static readonly MAX_CHUNKS_PER_RESPONSE: number = 50;

  /**
   * 去掉查询串再匹配路由。
   *
   * ⚠️ 与 `ApiResponseValidator.basePath()` 同一个坑：原先这里全是精确比较
   * （`path === '/api/v1/knowledge-bases'`），一旦调用方带上 `?userId=`
   * 就全部失配。目前那几条路由恰好不带参数，属于潜在缺陷，一并修掉。
   */
  private static basePath(path: string): string {
    const mark: number = path.indexOf('?');
    return mark >= 0 ? path.substring(0, mark) : path;
  }

  private static nextId(prefix: string): string {
    FixtureApiTransport.fixtureSeq++;
    return `${prefix}-fixture-${FixtureApiTransport.fixtureSeq}`;
  }

  /**
   * 离线 Fixture 的标准答案键 —— 必须与后端 `server/zhixue-agent-server/data/question_bank.json`
   * 逐字一致，否则"在线 / 离线"两种模式的分数会对不上，演示自相矛盾。
   *
   * ⚠️ 这三个值是锁死的：preorder=A、inorder=B、postorder=C。
   * 演示提交 √√×（A / B / A）才是 2 对 1 错 = 66.67。
   */
  private static readonly ANSWER_KEYS: Record<string, string> = {
    'exercise-preorder-001': 'A',
    'exercise-inorder-001': 'B',
    'exercise-postorder-001': 'C',
    'exercise-postorder-002': 'C',
    'exercise-postorder-003': 'C',
    'exercise-postorder-004': 'C'
  };

  static async request<T>(method: string, path: string, body?: Object): Promise<ApiResult<T>> {
    // 统一用去查询串的路径匹配：`?userId=` 之类不能再让精确比较失效。
    const route: string = FixtureApiTransport.basePath(path);
    if (method === 'POST' && route === '/api/v1/workflows') return apiSuccess<WorkflowResponse>(FixtureApiTransport.workflow(body as WorkflowCreateRequest), 'fixture') as ApiResult<T>;
    if (method === 'POST' && route.indexOf('/api/v1/workflows/') === 0 && route.endsWith('/run')) return apiSuccess<WorkflowRunResponse>(FixtureApiTransport.workflowRun(body as WorkflowRunRequest), 'fixture') as ApiResult<T>;
    if (method === 'GET' && route.indexOf('/api/v1/workflows/') === 0) return apiSuccess<WorkflowStatusResponse>(FixtureApiTransport.workflowStatus(), 'fixture') as ApiResult<T>;
    if (method === 'GET' && route.indexOf('/api/v1/profile/') === 0) return apiSuccess<ProfileResponse>(FixtureApiTransport.profile(), 'fixture') as ApiResult<T>;
    if (method === 'GET' && route === '/api/v1/plans/current') return apiSuccess<LearningPlan>(FixtureApiTransport.plan(), 'fixture') as ApiResult<T>;
    if (method === 'GET' && route.indexOf('/api/v1/exercises/') === 0 && !route.endsWith('/submit')) return apiSuccess<ExerciseSetResponse>(FixtureApiTransport.exerciseSet(path), 'fixture') as ApiResult<T>;
    if (method === 'POST' && route.indexOf('/api/v1/exercises/') === 0 && route.endsWith('/submit')) {
      FixtureDemoStateStore.markExerciseSubmitted();
      return apiSuccess<ExerciseSubmissionResult>(
        FixtureApiTransport.assessment((body as ExerciseSubmission)?.answers), 'fixture') as ApiResult<T>;
    }
    if (method === 'GET' && route.indexOf('/api/v1/plans/') === 0 && route.endsWith('/diff')) return apiSuccess<PlanDiff>(FixtureApiTransport.planDiff(), 'fixture') as ApiResult<T>;
    if (method === 'GET' && route.indexOf('/api/v1/traces/') === 0) return apiSuccess<TraceResponse>(FixtureApiTransport.trace(), 'fixture') as ApiResult<T>;

    // ---- 知识库：与后端 app/api/knowledge.py 同一份契约 ----
    if (method === 'POST' && route === '/api/v1/knowledge-bases') {
      return FixtureApiTransport.kbCreate(body as KnowledgeBaseCreateRequest) as ApiResult<T>;
    }
    if (method === 'POST' && route.indexOf('/api/v1/knowledge-bases/') === 0 && route.endsWith('/search')) {
      const kbId: string = FixtureApiTransport.segment(route, 4);
      return FixtureApiTransport.kbSearch(kbId, body as KnowledgeSearchRequest) as ApiResult<T>;
    }
    if (method === 'POST' && route.indexOf('/api/v1/knowledge-bases/') === 0 && route.endsWith('/documents')) {
      const kbId: string = FixtureApiTransport.segment(route, 4);
      return FixtureApiTransport.kbUpload(kbId, body as KnowledgeDocumentUploadRequest) as ApiResult<T>;
    }
    if (method === 'GET' && route.indexOf('/api/v1/knowledge-bases/') === 0 && route.endsWith('/documents')) {
      const kbId: string = FixtureApiTransport.segment(route, 4);
      return FixtureApiTransport.kbDocuments(kbId) as ApiResult<T>;
    }
    if (method === 'GET' && route === '/api/v1/knowledge-bases') {
      const userId: string = FixtureApiTransport.queryUserId(path);
      return FixtureApiTransport.kbList(userId) as ApiResult<T>;
    }
    if (method === 'GET' && route.indexOf('/api/v1/knowledge-bases/') === 0) {
      const kbId: string = FixtureApiTransport.segment(route, 4);
      return FixtureApiTransport.kbDetail(kbId) as ApiResult<T>;
    }
    if (method === 'DELETE' && route.indexOf('/api/v1/knowledge-bases/') === 0) {
      const kbId: string = FixtureApiTransport.segment(route, 4);
      return FixtureApiTransport.kbDelete(kbId) as ApiResult<T>;
    }
    if (method === 'GET' && route.indexOf('/api/v1/documents/') === 0) {
      const documentId: string = FixtureApiTransport.segment(route, 3);
      return FixtureApiTransport.kbDocumentDetail(documentId) as ApiResult<T>;
    }
    if (method === 'DELETE' && route.indexOf('/api/v1/documents/') === 0) {
      const documentId: string = FixtureApiTransport.segment(route, 3);
      return FixtureApiTransport.kbDocumentDelete(documentId) as ApiResult<T>;
    }

    if (method === 'POST' && route === '/api/v1/demo/reset') {
      FixtureDemoStateStore.reset();
      FixtureApiTransport.resetKnowledge();
      return apiSuccess<DemoResetResponse>(FixtureApiTransport.reset(), 'fixture') as ApiResult<T>;
    }
    if (method === 'POST' && route === '/api/v1/agent/proactive') {
      return apiSuccess<ProactiveResponse>(FixtureApiTransport.proactive(body as ProactiveRequest), 'fixture') as ApiResult<T>;
    }
    return apiFailure('FIXTURE_ROUTE_NOT_FOUND', `未找到 fixture 路由：${method} ${path}`, false, 'fixture') as ApiResult<T>;
  }

  /**
   * 与后端 `app/tools/assessment_tools.grade_exercise` 同一条确定性规则：
   * 只统计有效题目，score = 正确数 / 有效题数 × 100（保留两位小数）。
   * 这样离线演示时改答案分数也会变，不会出现"随便选都是 67"的穿帮。
   */
  private static grade(answers?: ExerciseAnswer[]): number {
    if (answers === undefined || answers.length === 0) {
      return 66.67;
    }
    let valid: number = 0;
    let correct: number = 0;
    for (let index: number = 0; index < answers.length; index++) {
      const expected: string | undefined = FixtureApiTransport.ANSWER_KEYS[answers[index].exerciseId];
      if (expected === undefined) {
        continue;
      }
      valid++;
      if (answers[index].answer.trim().toUpperCase() === expected) {
        correct++;
      }
    }
    if (valid === 0) {
      return 0;
    }
    return Math.round((correct / valid) * 10000) / 100;
  }

  /** 与后端 `update_mastery` 同一条分档规则（保持 66.67 → 42→58 的演示基线）。 */
  private static nextMastery(oldScore: number, score: number): number {
    let delta: number;
    if (score === 100) {
      delta = 29;
    } else if (score >= 60) {
      delta = 16;
    } else if (score >= 40) {
      delta = 4;
    } else {
      delta = -4;
    }
    return Math.max(0, Math.min(100, oldScore + delta));
  }

  private static evidence(): Evidence {
    return { id: 'evidence-demo-001', sourceType: 'exercise', sourceId: 'set-demo-binary-tree-001', knowledgePointId: 'binary-tree-postorder', metric: 'perKnowledgeAccuracy', value: 0.67, timestamp: '2026-09-02T09:30:00Z', reliability: 1 };
  }

  private static profile(): ProfileResponse {
    const exerciseSubmitted: boolean = FixtureDemoStateStore.isExerciseSubmitted();
    const masteryScore: number = exerciseSubmitted ? FixtureDemoStateStore.getMasteryScore() : 42;
    const mastery: KnowledgeMastery[] = [{ knowledgePointId: 'binary-tree-postorder', knowledgePointName: '二叉树后序遍历', masteryScore: masteryScore, confidence: 0.7, lastUpdated: '2026-09-02T09:00:00Z' }];
    return { profileVersion: exerciseSubmitted ? 2 : 1, profile: { userId: ApiDefaults.DEMO_USER_ID, goal: '数据结构考试80+', examDate: '2026-09-30', freeTimeSlots: ['20:00-22:00'], profileVersion: exerciseSubmitted ? 2 : 1, mastery: mastery }, mastery: mastery, history: exerciseSubmitted ? [{ oldScore: 42, newScore: masteryScore, evidenceIds: ['evidence-demo-001'], source: 'assessment', timestamp: '2026-09-02T09:30:00Z' }] : [], evidence: exerciseSubmitted ? [FixtureApiTransport.evidence()] : [] };
  }

  private static plan(): LearningPlan {
    const replanned: boolean = FixtureDemoStateStore.isExerciseSubmitted()
      && FixtureDemoStateStore.getAssessmentScore() < 80;
    const minutes: number[] = FixtureApiTransport.planMinutes();
    return { planId: 'plan-demo-001', version: replanned ? 2 : 1, generatedFromProfileVersion: replanned ? 2 : 1, reason: replanned ? '掌握度仍低于巩固阈值，已自动重规划。' : '巩固二叉树后序遍历', factors: FixtureApiTransport.factors(), tasks: [
      { taskId: 'task-postorder', knowledgePointId: 'binary-tree-postorder', knowledgePointName: '二叉树后序遍历', durationMinutes: replanned ? minutes[0] : 30, status: 'pending', priority: 'high' },
      { taskId: 'task-graph', knowledgePointId: 'graph-traversal', knowledgePointName: '图算法遍历', durationMinutes: replanned ? minutes[1] : 30, status: 'pending', priority: 'medium' }
    ] };
  }

  /** 与后端 plan_tools 的分档一致：正确率越低，薄弱点获得的时间越多。 */
  private static planMinutes(): number[] {
    const score: number = FixtureDemoStateStore.getAssessmentScore();
    if (score >= 80) return [40, 20];
    if (score >= 60) return [45, 15];
    if (score >= 30) return [50, 15];
    return [55, 15];
  }

  private static factors(): DecisionFactor[] {
    return [
      { name: '1-Mastery', value: 0.58, weight: 0.30, contribution: 0.174 },
      { name: 'ErrorIntensity', value: 0.67, weight: 0.25, contribution: 0.168 },
      { name: 'Importance', value: 0.90, weight: 0.20, contribution: 0.180 },
      { name: 'Urgency', value: 0.53, weight: 0.15, contribution: 0.080 },
      { name: 'PrerequisiteImpact', value: 0.20, weight: 0.10, contribution: 0.020 }
    ];
  }

  private static proactive(request?: ProactiveRequest): ProactiveResponse {
    const context = request?.context;
    const shouldNotify: boolean = context?.focusSessionActive !== true && context?.foreground !== true;
    return {
      userId: request?.userId ?? ApiDefaults.DEMO_USER_ID,
      shouldNotify: shouldNotify,
      channel: shouldNotify ? 'reminder' : 'silent',
      title: shouldNotify ? '数据结构考试还有 5 天' : '',
      body: shouldNotify ? '后序遍历掌握度偏低，建议现在用 45 分钟补强。' : '当前无需打扰。',
      action: shouldNotify
        ? { type: 'focus', targetPage: 'pages/FocusSetup', preset: { taskId: 'task-postorder', durationMinutes: 45 } }
        : { type: 'none', targetPage: '', preset: {} },
      contextTags: shouldNotify ? ['exam_within_7d', 'recent_gap_2d'] : [],
      reason: shouldNotify ? '考试临近、掌握度偏低且近期复习不足。' : '用户正在应用内或专注中，不主动打扰。',
      factors: shouldNotify ? FixtureApiTransport.factors() : [],
      cardData: { taskName: '二叉树后序遍历', durationMinutes: 45, examCountdownDays: 5,
        hint: shouldNotify ? '近期复习不足 · 2 项作业临近' : '' }
    };
  }

  private static workflow(request?: WorkflowCreateRequest): WorkflowResponse {
    return { sessionId: request?.sessionId ?? 'session-demo-001', traceId: 'trace-demo-001', status: 'running', currentStep: 'diagnosis', nextAction: 'diagnose' };
  }

  private static workflowStatus(): WorkflowStatusResponse {
    const exerciseSubmitted: boolean = FixtureDemoStateStore.isExerciseSubmitted();
    return { status: exerciseSubmitted ? 'completed' : 'running', currentAgent: exerciseSubmitted ? 'planner' : 'diagnosis', stateVersion: exerciseSubmitted ? 5 : 2, finalAction: exerciseSubmitted ? '查看 Plan V2' : null };
  }

  private static workflowRun(request?: WorkflowRunRequest): WorkflowRunResponse {
    const status: WorkflowStatusResponse = FixtureApiTransport.workflowStatus();
    const state: Record<string, Object> = {};
    if (request?.submissionId !== undefined) {
      state['submissionId'] = request.submissionId;
    }
    return { sessionId: 'session-demo-001', traceId: 'trace-demo-001', status: status.status,
      currentStep: status.currentAgent ?? 'finish', currentAgent: status.currentAgent ?? 'finish',
      stateVersion: status.stateVersion, finalAction: status.finalAction,
      state: state };
  }

  private static exerciseSet(path: string): ExerciseSetResponse {
    const refreshed: boolean = path.indexOf('excludeExerciseId=') >= 0;
    const excludesSecondGroup: boolean = path.indexOf('exercise-postorder-002') >= 0;
    const first: Exercise[] = [
      { exerciseId: 'exercise-preorder-001', knowledgePointId: 'binary-tree-postorder', knowledgePointName: '二叉树后序遍历', difficulty: 'easy', stem: '以下哪项是给定二叉树的前序遍历结果？', options: ['A. 根-左-右', 'B. 左-右-根', 'C. 左-根-右', 'D. 根-右-左'], source: 'demo' },
      { exerciseId: 'exercise-inorder-001', knowledgePointId: 'binary-tree-postorder', knowledgePointName: '二叉树后序遍历', difficulty: 'easy', stem: '二叉树中序遍历访问节点的顺序是什么？', options: ['A. 根-左-右', 'B. 左-根-右', 'C. 左-右-根', 'D. 根-右-左'], source: 'demo' },
      { exerciseId: 'exercise-postorder-001', knowledgePointId: 'binary-tree-postorder', knowledgePointName: '二叉树后序遍历', difficulty: 'medium', stem: '二叉树后序遍历访问节点的顺序是什么？', options: ['A. 根-左-右', 'B. 左-根-右', 'C. 左-右-根', 'D. 根-右-左'], source: 'demo' }
    ];
    const next: Exercise[] = [
      { exerciseId: 'exercise-postorder-002', knowledgePointId: 'binary-tree-postorder', knowledgePointName: '二叉树后序遍历', difficulty: 'easy', stem: '后序遍历中，根节点通常在什么时候被访问？', options: ['A. 最先', 'B. 左子树之后、右子树之前', 'C. 左右子树都访问后', 'D. 任意时刻'], source: 'demo' },
      { exerciseId: 'exercise-postorder-003', knowledgePointId: 'binary-tree-postorder', knowledgePointName: '二叉树后序遍历', difficulty: 'medium', stem: '表达式树用后序遍历得到的结果最接近哪种表达式？', options: ['A. 前缀表达式', 'B. 中缀表达式', 'C. 后缀表达式', 'D. 自然语言'], source: 'demo' },
      { exerciseId: 'exercise-postorder-004', knowledgePointId: 'binary-tree-postorder', knowledgePointName: '二叉树后序遍历', difficulty: 'medium', stem: '递归实现后序遍历时，输出当前节点应放在哪一步？', options: ['A. 递归左子树前', 'B. 递归左右子树之间', 'C. 递归左右子树后', 'D. 只在叶节点执行'], source: 'demo' }
    ];
    return { setId: 'set-demo-binary-tree-001',
      exercises: refreshed ? (excludesSecondGroup ? first : next) : first };
  }

  private static assessment(answers?: ExerciseAnswer[]): ExerciseSubmissionResult {
    const score: number = FixtureApiTransport.grade(answers);
    const newMastery: number = FixtureApiTransport.nextMastery(42, score);
    FixtureDemoStateStore.setAssessmentResult(newMastery, score);
    const perKnowledge: Record<string, number> = {};
    perKnowledge['binary-tree-postorder'] = score;
    return { userId: ApiDefaults.DEMO_USER_ID, submissionId: ApiDefaults.DEMO_USER_ID + ':set-demo-binary-tree-001:fixture-submission', assessment: { score: score, perKnowledgeAccuracy: perKnowledge, errorTypes: score < 100 ? ['后序遍历顺序混淆'] : [], oldMastery: 42, suggestedNewMastery: newMastery }, masteryUpdate: { knowledgePointId: 'binary-tree-postorder', oldScore: 42, newScore: newMastery }, needReplan: score < 80, plan: FixtureApiTransport.plan(), planDiff: FixtureApiTransport.planDiff() };
  }

  private static planDiff(): PlanDiff {
    if (FixtureDemoStateStore.getAssessmentScore() >= 80) {
      return { planId: 'plan-demo-001', oldVersion: 1, newVersion: 1, changedTasks: [],
        adjustmentReason: '本次掌握良好，无需调整计划', triggerEvidence: ['evidence-demo-001'] };
    }
    const minutes: number[] = FixtureApiTransport.planMinutes();
    return { planId: 'plan-demo-001', oldVersion: 1, newVersion: 2, changedTasks: [{ taskId: 'task-postorder', knowledgePointId: 'binary-tree-postorder', durationMinutes: minutes[0], change: `+${minutes[0] - 30}` }, { taskId: 'task-graph', knowledgePointId: 'graph-traversal', durationMinutes: minutes[1], change: `${minutes[1] - 30}` }], adjustmentReason: `按本次正确率 ${FixtureDemoStateStore.getAssessmentScore()}% 动态调整`, triggerEvidence: ['evidence-demo-001'] };
  }

  private static trace(): TraceResponse {
    if (!FixtureDemoStateStore.isExerciseSubmitted()) {
      return { traceId: 'trace-demo-001', events: [
        { agent: 'secretary', toolCalls: ['get_learner_profile'], inputSummary: '读取 demo-user 学习状态', outputSummary: '发现 mastery=42，需要进入专项诊断', evidenceIds: [], stateVersion: 1, timestamp: '2026-09-02T09:00:00Z', status: 'success' },
        { agent: 'diagnosis', toolCalls: ['select_knowledge_point'], inputSummary: '结合目标与当前掌握度筛选薄弱点', outputSummary: '选择二叉树后序遍历作为本轮练习主题', evidenceIds: [], stateVersion: 2, timestamp: '2026-09-02T09:01:00Z', status: 'success' }
      ] };
    }
    return { traceId: 'trace-demo-001', events: [
      { agent: 'secretary', toolCalls: ['get_learner_profile'], inputSummary: '读取 demo-user 学习状态', outputSummary: '发现 mastery=42，需要进入专项诊断', evidenceIds: [], stateVersion: 1, timestamp: '2026-09-02T09:00:00Z', status: 'success' },
      { agent: 'diagnosis', toolCalls: ['select_knowledge_point'], inputSummary: '结合目标与当前掌握度筛选薄弱点', outputSummary: '选择二叉树后序遍历作为本轮练习主题', evidenceIds: [], stateVersion: 2, timestamp: '2026-09-02T09:01:00Z', status: 'success' },
      { agent: 'exercise', toolCalls: ['generate_exercise_set'], inputSummary: '生成 3 道二叉树遍历专项题', outputSummary: '练习集已生成并完成作答提交', evidenceIds: [], stateVersion: 3, timestamp: '2026-09-02T09:20:00Z', status: 'success' },
      { agent: 'assessment', toolCalls: ['assess_submission', 'update_mastery'], inputSummary: '根据答题结果生成诊断证据', outputSummary: '正确率 67%，掌握度由 42 更新为 58', evidenceIds: ['evidence-demo-001'], stateVersion: 4, timestamp: '2026-09-02T09:30:00Z', status: 'success' },
      { agent: 'planner', toolCalls: ['replan_current_plan'], inputSummary: '掌握度 58 仍低于巩固阈值 60', outputSummary: '生成 Plan V2，专项练习时长增加 15 分钟', evidenceIds: ['evidence-demo-001'], stateVersion: 5, timestamp: '2026-09-02T09:31:00Z', status: 'success' }
    ] };
  }

  // ------------------------------------------------------------ 知识库（离线）
  /** 取 `/<a>/<b>/<c>...` 里的第 index 段（0 = 第一个 `/` 之后）。 */
  private static segment(route: string, index: number): string {
    const parts: string[] = route.split('/');
    return index < parts.length ? parts[index] : '';
  }

  /** 从查询串里取 `userId`；没有则回落到演示身份（与后端一致）。 */
  private static queryUserId(path: string): string {
    const mark: number = path.indexOf('?');
    if (mark < 0) {
      return ApiDefaults.DEMO_USER_ID;
    }
    const query: string = path.substring(mark + 1);
    const pairs: string[] = query.split('&');
    for (let i: number = 0; i < pairs.length; i++) {
      const eq: number = pairs[i].indexOf('=');
      if (eq > 0 && pairs[i].substring(0, eq) === 'userId') {
        const value: string = decodeURIComponent(pairs[i].substring(eq + 1));
        return value.length > 0 ? value : ApiDefaults.DEMO_USER_ID;
      }
    }
    return ApiDefaults.DEMO_USER_ID;
  }

  /** `POST /api/v1/demo/reset` 时一并清空离线知识库。 */
  private static resetKnowledge(): void {
    FixtureApiTransport.fixtureKbs = [];
    FixtureApiTransport.fixtureDocs = [];
    FixtureApiTransport.fixtureChunks = [];
    FixtureApiTransport.fixtureSeq = 0;
  }

  private static kbList(userId: string): ApiResult<KnowledgeBaseListResponse> {
    const mine: KnowledgeBase[] = [];
    for (let i: number = 0; i < FixtureApiTransport.fixtureKbs.length; i++) {
      if (FixtureApiTransport.fixtureKbs[i].userId === userId) {
        mine.push(FixtureApiTransport.fixtureKbs[i]);
      }
    }
    return apiSuccess<KnowledgeBaseListResponse>({ knowledgeBases: mine, total: mine.length }, 'fixture');
  }

  private static kbCreate(request: KnowledgeBaseCreateRequest): ApiResult<KnowledgeBase> {
    const courseName: string = (request?.courseName ?? '').trim();
    const name: string = (request?.name ?? '').trim();
    if (courseName.length === 0 || name.length === 0) {
      return apiFailure('VALIDATION_ERROR', '课程名与知识库名称不能为空。', false, 'fixture');
    }
    // 先落到局部变量：ArkTS 不会从三元表达式的判断里收窄 `request.userId`，
    // 直接写 `... ? request.userId : ...` 会报 string | undefined 不可赋值。
    const ownerId: string = (request?.userId ?? '').length > 0
      ? (request?.userId as string) : ApiDefaults.DEMO_USER_ID;
    for (let i: number = 0; i < FixtureApiTransport.fixtureKbs.length; i++) {
      const existing: KnowledgeBase = FixtureApiTransport.fixtureKbs[i];
      if (existing.userId === ownerId && existing.courseName.trim().toLowerCase() === courseName.toLowerCase()) {
        return apiFailure('CONFLICT', `课程「${courseName}」已有资料库，请直接上传文档。`, false, 'fixture');
      }
    }
    const now: string = new Date().toISOString();
    const kb: KnowledgeBase = {
      kbId: FixtureApiTransport.nextId('kb'),
      userId: ownerId,
      courseName: courseName,
      name: name,
      description: request?.description ?? '',
      documentCount: 0,
      chunkCount: 0,
      knowledgePoints: [],
      createdAt: now,
      updatedAt: now
    };
    FixtureApiTransport.fixtureKbs.push(kb);
    return apiSuccess<KnowledgeBase>(kb, 'fixture');
  }

  private static kbFind(kbId: string): KnowledgeBase | null {
    for (let i: number = 0; i < FixtureApiTransport.fixtureKbs.length; i++) {
      if (FixtureApiTransport.fixtureKbs[i].kbId === kbId) {
        return FixtureApiTransport.fixtureKbs[i];
      }
    }
    return null;
  }

  private static kbDetail(kbId: string): ApiResult<KnowledgeBaseDetail> {
    const kb: KnowledgeBase | null = FixtureApiTransport.kbFind(kbId);
    if (kb === null) {
      return apiFailure('NOT_FOUND', '知识库不存在。', false, 'fixture');
    }
    const docs: KnowledgeDocument[] = FixtureApiTransport.docsOf(kbId);
    const detail: KnowledgeBaseDetail = {
      kbId: kb.kbId, userId: kb.userId, courseName: kb.courseName, name: kb.name,
      description: kb.description, documentCount: docs.length,
      chunkCount: kb.chunkCount ?? 0, knowledgePoints: kb.knowledgePoints ?? [],
      createdAt: kb.createdAt, updatedAt: kb.updatedAt, documents: docs
    };
    return apiSuccess<KnowledgeBaseDetail>(detail, 'fixture');
  }

  private static docsOf(kbId: string): KnowledgeDocument[] {
    const docs: KnowledgeDocument[] = [];
    for (let i: number = 0; i < FixtureApiTransport.fixtureDocs.length; i++) {
      if (FixtureApiTransport.fixtureDocs[i].kbId === kbId) {
        docs.push(FixtureApiTransport.fixtureDocs[i]);
      }
    }
    return docs;
  }

  private static kbDocuments(kbId: string): ApiResult<KnowledgeDocumentListResponse> {
    const docs: KnowledgeDocument[] = FixtureApiTransport.docsOf(kbId);
    return apiSuccess<KnowledgeDocumentListResponse>({ kbId: kbId, documents: docs, total: docs.length }, 'fixture');
  }

  private static kbDelete(kbId: string): ApiResult<KnowledgeBase> {
    const kb: KnowledgeBase | null = FixtureApiTransport.kbFind(kbId);
    if (kb === null) {
      return apiFailure('NOT_FOUND', '知识库不存在。', false, 'fixture');
    }
    const keptKbs: KnowledgeBase[] = [];
    for (let i: number = 0; i < FixtureApiTransport.fixtureKbs.length; i++) {
      if (FixtureApiTransport.fixtureKbs[i].kbId !== kbId) {
        keptKbs.push(FixtureApiTransport.fixtureKbs[i]);
      }
    }
    FixtureApiTransport.fixtureKbs = keptKbs;
    FixtureApiTransport.fixtureDocs = FixtureApiTransport.fixtureDocs.filter((doc: KnowledgeDocument) => doc.kbId !== kbId);
    FixtureApiTransport.fixtureChunks = FixtureApiTransport.fixtureChunks.filter((chunk: FixtureChunk) => chunk.kbId !== kbId);
    return apiSuccess<KnowledgeBase>(kb, 'fixture');
  }

  /**
   * 文档详情（含正文）——`GET /api/v1/documents/{documentId}`。
   *
   * 离线切片本来就留在内存（`fixtureChunks`），这里**如实回传**，不编造正文；
   * 截断上限与后端 `knowledge.MAX_CHUNKS_PER_RESPONSE` 保持一致，
   * 超过同样标注 `chunksTruncated=true` —— 离线演示也不能静默截断。
   */
  private static kbDocumentDetail(documentId: string): ApiResult<KnowledgeDocumentDetail> {
    let target: KnowledgeDocument | null = null;
    for (let i: number = 0; i < FixtureApiTransport.fixtureDocs.length; i++) {
      if (FixtureApiTransport.fixtureDocs[i].documentId === documentId) {
        target = FixtureApiTransport.fixtureDocs[i];
      }
    }
    if (target === null) {
      return apiFailure('NOT_FOUND', '文档不存在。', false, 'fixture');
    }
    const all: KnowledgeDocumentChunk[] = [];
    for (let i: number = 0; i < FixtureApiTransport.fixtureChunks.length; i++) {
      const chunk: FixtureChunk = FixtureApiTransport.fixtureChunks[i];
      if (chunk.documentId === documentId) {
        all.push({
          chunkId: chunk.chunkId,
          index: all.length + 1,
          headingPath: chunk.headingPath,
          text: chunk.text,
          knowledgePoints: chunk.headingPath.length > 0 ? [chunk.headingPath] : []
        });
      }
    }
    const total: number = all.length;
    const returned: KnowledgeDocumentChunk[] = total > FixtureApiTransport.MAX_CHUNKS_PER_RESPONSE
      ? all.slice(0, FixtureApiTransport.MAX_CHUNKS_PER_RESPONSE) : all;
    const detail: KnowledgeDocumentDetail = {
      documentId: target.documentId, kbId: target.kbId, userId: target.userId,
      fileName: target.fileName, mimeType: target.mimeType, sizeBytes: target.sizeBytes,
      status: target.status, statusMessage: target.statusMessage,
      charCount: target.charCount, chunkCount: target.chunkCount,
      knowledgePoints: target.knowledgePoints, errorPointCandidates: target.errorPointCandidates,
      uploadedAt: target.uploadedAt, parsedAt: target.parsedAt,
      chunks: returned, chunkTotal: total, chunksTruncated: total > returned.length
    };
    return apiSuccess<KnowledgeDocumentDetail>(detail, 'fixture');
  }

  private static kbDocumentDelete(documentId: string): ApiResult<KnowledgeDocument> {
    let target: KnowledgeDocument | null = null;
    for (let i: number = 0; i < FixtureApiTransport.fixtureDocs.length; i++) {
      if (FixtureApiTransport.fixtureDocs[i].documentId === documentId) {
        target = FixtureApiTransport.fixtureDocs[i];
      }
    }
    if (target === null) {
      return apiFailure('NOT_FOUND', '文档不存在。', false, 'fixture');
    }
    FixtureApiTransport.fixtureDocs =
      FixtureApiTransport.fixtureDocs.filter((doc: KnowledgeDocument) => doc.documentId !== documentId);
    FixtureApiTransport.fixtureChunks =
      FixtureApiTransport.fixtureChunks.filter((chunk: FixtureChunk) => chunk.documentId !== documentId);
    const kb: KnowledgeBase | null = FixtureApiTransport.kbFind(target.kbId);
    if (kb !== null) {
      const remaining: KnowledgeDocument[] = FixtureApiTransport.docsOf(kb.kbId);
      kb.documentCount = remaining.length;
      kb.chunkCount = FixtureApiTransport.countChunks(kb.kbId);
      kb.updatedAt = new Date().toISOString();
    }
    return apiSuccess<KnowledgeDocument>(target, 'fixture');
  }

  private static countChunks(kbId: string): number {
    let count: number = 0;
    for (let i: number = 0; i < FixtureApiTransport.fixtureChunks.length; i++) {
      if (FixtureApiTransport.fixtureChunks[i].kbId === kbId) {
        count++;
      }
    }
    return count;
  }

  /**
   * 上传并"解析"。
   *
   * 解析规则与后端 `app/agent/knowledge.py` 同源：按 Markdown 标题切块，
   * 标题行作为 `headingPath`（引用来源），标题文本作为知识点。
   * 这样离线演示看到的切片数 / 知识点不是编的。
   */
  private static kbUpload(kbId: string, request: KnowledgeDocumentUploadRequest): ApiResult<KnowledgeDocument> {
    const kb: KnowledgeBase | null = FixtureApiTransport.kbFind(kbId);
    if (kb === null) {
      return apiFailure('NOT_FOUND', '知识库不存在。', false, 'fixture');
    }
    const fileName: string = (request?.fileName ?? '').trim();
    if (fileName.length === 0) {
      return apiFailure('VALIDATION_ERROR', '文件名不能为空。', false, 'fixture');
    }
    const lower: string = fileName.toLowerCase();
    const unsupported: boolean = lower.endsWith('.pdf') || lower.endsWith('.doc')
      || lower.endsWith('.docx') || lower.endsWith('.xls') || lower.endsWith('.xlsx');
    const now: string = new Date().toISOString();
    if (unsupported) {
      // 失败态照实返回 —— 与在线后端一样"能失败、能重试"，不假装成功。
      const failed: KnowledgeDocument = {
        documentId: FixtureApiTransport.nextId('doc'), kbId: kbId, userId: kb.userId,
        fileName: fileName, status: 'failed',
        statusMessage: '当前支持 TXT / Markdown / CSV / JSON，PDF 与 Office 文档暂不支持。',
        uploadedAt: now
      };
      FixtureApiTransport.fixtureDocs.push(failed);
      kb.documentCount = FixtureApiTransport.docsOf(kbId).length;
      kb.updatedAt = now;
      return apiSuccess<KnowledgeDocument>(failed, 'fixture');
    }

    const text: string = FixtureApiTransport.decodeBase64(request?.contentBase64 ?? '');
    const points: string[] = [];
    const errorPoints: string[] = [];
    const chunks: FixtureChunk[] = [];
    const lines: string[] = text.split('\n');
    let heading: string = '';
    let buffer: string[] = [];

    const flush = (): void => {
      const body: string = buffer.join(' ').trim();
      if (body.length === 0) {
        return;
      }
      FixtureApiTransport.fixtureSeq++;
      chunks.push({
        chunkId: `chunk-fixture-${FixtureApiTransport.fixtureSeq}`,
        documentId: '', kbId: kbId, fileName: fileName,
        headingPath: heading, text: body
      });
      if (heading.length > 0 && points.indexOf(heading) < 0) {
        points.push(heading);
      }
      if (body.indexOf('常见错误') >= 0 || body.indexOf('注意') >= 0 || body.indexOf('易错') >= 0) {
        errorPoints.push(body.length > 60 ? body.substring(0, 60) : body);
      }
      buffer = [];
    };

    for (let i: number = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.indexOf('#') === 0) {
        flush();
        heading = line.replace(/^#+\s*/, '').trim();
      } else if (line.length === 0) {
        flush();
      } else {
        buffer.push(line);
      }
    }
    flush();

    const documentId: string = FixtureApiTransport.nextId('doc');
    for (let i: number = 0; i < chunks.length; i++) {
      chunks[i].documentId = documentId;
    }
    for (let i: number = 0; i < chunks.length; i++) {
      FixtureApiTransport.fixtureChunks.push(chunks[i]);
    }

    const doc: KnowledgeDocument = {
      documentId: documentId, kbId: kbId, userId: kb.userId, fileName: fileName,
      mimeType: request?.mimeType ?? 'text/plain',
      sizeBytes: request?.sizeBytes ?? text.length,
      status: 'ready', statusMessage: '',
      charCount: text.length, chunkCount: chunks.length,
      knowledgePoints: points, errorPointCandidates: errorPoints,
      uploadedAt: now, parsedAt: now
    };
    FixtureApiTransport.fixtureDocs.push(doc);
    kb.documentCount = FixtureApiTransport.docsOf(kbId).length;
    kb.chunkCount = FixtureApiTransport.countChunks(kbId);
    const merged: string[] = kb.knowledgePoints ?? [];
    for (let i: number = 0; i < points.length; i++) {
      if (merged.indexOf(points[i]) < 0) {
        merged.push(points[i]);
      }
    }
    kb.knowledgePoints = merged;
    kb.updatedAt = now;
    return apiSuccess<KnowledgeDocument>(doc, 'fixture');
  }

  /** base64 → 文本。解码失败返回空串，由调用方给出可读提示（不抛异常）。 */
  private static decodeBase64(content: string): string {
    if (content.length === 0) {
      return '';
    }
    try {
      const helper: util.Base64Helper = new util.Base64Helper();
      const bytes: Uint8Array = helper.decodeSync(content);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: false });
      return decoder.decodeToString(bytes);
    } catch (error) {
      return '';
    }
  }

  /**
   * 关键词检索。
   *
   * 离线**不做语义检索**，所以 `retrievalMode` 如实标 `keyword+tag`、
   * `semanticAvailable=false`、`semanticWeight=0` —— 与后端未配 Key 时的标注一致，
   * 不假装有向量能力。
   */
  private static kbSearch(kbId: string, request: KnowledgeSearchRequest): ApiResult<KnowledgeSearchResponse> {
    const kb: KnowledgeBase | null = FixtureApiTransport.kbFind(kbId);
    if (kb === null) {
      return apiFailure('NOT_FOUND', '知识库不存在。', false, 'fixture');
    }
    const query: string = (request?.query ?? '').trim();
    const terms: string[] = query.length > 0 ? query.split(/\s+/) : [];
    const hits: KnowledgeChunkHit[] = [];
    let scanned: number = 0;
    for (let i: number = 0; i < FixtureApiTransport.fixtureChunks.length; i++) {
      const chunk: FixtureChunk = FixtureApiTransport.fixtureChunks[i];
      if (chunk.kbId !== kbId) {
        continue;
      }
      scanned++;
      let score: number = 0;
      for (let t: number = 0; t < terms.length; t++) {
        if (terms[t].length > 0 && chunk.text.indexOf(terms[t]) >= 0) {
          score += 1;
        }
      }
      // 无查询词时不做命中（与后端"空查询返回空"一致），有词才按命中数打分
      if (terms.length > 0 && score > 0) {
        hits.push({
          chunkId: chunk.chunkId, documentId: chunk.documentId, fileName: chunk.fileName,
          headingPath: chunk.headingPath, text: chunk.text,
          knowledgePoints: chunk.headingPath.length > 0 ? [chunk.headingPath] : [],
          score: Math.round((score / terms.length) * 100) / 100
        });
      }
    }
    hits.sort((a: KnowledgeChunkHit, b: KnowledgeChunkHit) => b.score - a.score);
    const topK: number = request?.topK ?? 5;
    const trimmed: KnowledgeChunkHit[] = hits.length > topK ? hits.slice(0, topK) : hits;
    return apiSuccess<KnowledgeSearchResponse>({
      kbId: kbId, query: query, hits: trimmed, totalScanned: scanned,
      retrievalMode: 'keyword+tag', semanticAvailable: false, semanticWeight: 0
    }, 'fixture');
  }

  private static reset(): DemoResetResponse {
    const profile: ProfileResponse = FixtureApiTransport.profile();
    return { status: 'reset', userId: ApiDefaults.DEMO_USER_ID, profile: profile.profile ?? null, plan: FixtureApiTransport.plan(), traceId: 'trace-demo-001' };
  }
}
