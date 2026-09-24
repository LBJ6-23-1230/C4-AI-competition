import { DecisionFactor, DemoResetResponse, Evidence, ExerciseAnswer, ExerciseSetResponse, ExerciseSubmission, ExerciseSubmissionResult, KnowledgeMastery, LearningPlan, PlanDiff, ProactiveRequest, ProactiveResponse, ProfileResponse, TraceResponse, WorkflowCreateRequest, WorkflowResponse, WorkflowRunRequest, WorkflowRunResponse, WorkflowStatusResponse } from './ApiModels';
import { ApiResult, apiFailure, apiSuccess } from './ApiResult';
import { ApiDefaults } from './ApiDefaults';
import { FixtureDemoStateStore } from './FixtureDemoStateStore';

/** Deterministic offline transport mirroring the api-contract-v0.3 payloads. */
export class FixtureApiTransport {
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
    'exercise-postorder-001': 'C'
  };

  static async request<T>(method: string, path: string, body?: Object): Promise<ApiResult<T>> {
    if (method === 'POST' && path === '/api/v1/workflows') return apiSuccess<WorkflowResponse>(FixtureApiTransport.workflow(body as WorkflowCreateRequest), 'fixture') as ApiResult<T>;
    if (method === 'POST' && path.indexOf('/api/v1/workflows/') === 0 && path.endsWith('/run')) return apiSuccess<WorkflowRunResponse>(FixtureApiTransport.workflowRun(body as WorkflowRunRequest), 'fixture') as ApiResult<T>;
    if (method === 'GET' && path.indexOf('/api/v1/workflows/') === 0) return apiSuccess<WorkflowStatusResponse>(FixtureApiTransport.workflowStatus(), 'fixture') as ApiResult<T>;
    if (method === 'GET' && path.indexOf('/api/v1/profile/') === 0) return apiSuccess<ProfileResponse>(FixtureApiTransport.profile(), 'fixture') as ApiResult<T>;
    if (method === 'GET' && path === '/api/v1/plans/current') return apiSuccess<LearningPlan>(FixtureApiTransport.plan(), 'fixture') as ApiResult<T>;
    if (method === 'GET' && path.indexOf('/api/v1/exercises/') === 0 && !path.endsWith('/submit')) return apiSuccess<ExerciseSetResponse>(FixtureApiTransport.exerciseSet(), 'fixture') as ApiResult<T>;
    if (method === 'POST' && path.indexOf('/api/v1/exercises/') === 0 && path.endsWith('/submit')) {
      FixtureDemoStateStore.markExerciseSubmitted();
      return apiSuccess<ExerciseSubmissionResult>(
        FixtureApiTransport.assessment((body as ExerciseSubmission)?.answers), 'fixture') as ApiResult<T>;
    }
    if (method === 'GET' && path.indexOf('/api/v1/plans/') === 0 && path.endsWith('/diff')) return apiSuccess<PlanDiff>(FixtureApiTransport.planDiff(), 'fixture') as ApiResult<T>;
    if (method === 'GET' && path.indexOf('/api/v1/traces/') === 0) return apiSuccess<TraceResponse>(FixtureApiTransport.trace(), 'fixture') as ApiResult<T>;
    if (method === 'POST' && path === '/api/v1/demo/reset') {
      FixtureDemoStateStore.reset();
      return apiSuccess<DemoResetResponse>(FixtureApiTransport.reset(), 'fixture') as ApiResult<T>;
    }
    if (method === 'POST' && path === '/api/v1/agent/proactive') {
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
    const replanned: boolean = FixtureDemoStateStore.isExerciseSubmitted();
    return { planId: 'plan-demo-001', version: replanned ? 2 : 1, generatedFromProfileVersion: replanned ? 2 : 1, reason: replanned ? '掌握度仍低于巩固阈值，已自动重规划。' : '巩固二叉树后序遍历', factors: FixtureApiTransport.factors(), tasks: [
      { taskId: 'task-postorder', knowledgePointId: 'binary-tree-postorder', knowledgePointName: '二叉树后序遍历', durationMinutes: replanned ? 45 : 30, status: 'pending', priority: 'high' },
      { taskId: 'task-graph', knowledgePointId: 'graph-traversal', knowledgePointName: '图算法遍历', durationMinutes: replanned ? 15 : 30, status: 'pending', priority: 'medium' }
    ] };
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

  private static exerciseSet(): ExerciseSetResponse {
    return { setId: 'set-demo-binary-tree-001', exercises: [
      { exerciseId: 'exercise-preorder-001', knowledgePointId: 'binary-tree-postorder', knowledgePointName: '二叉树后序遍历', difficulty: 'easy', stem: '以下哪项是给定二叉树的前序遍历结果？', options: ['A. 根-左-右', 'B. 左-右-根', 'C. 左-根-右', 'D. 根-右-左'], source: 'demo' },
      { exerciseId: 'exercise-inorder-001', knowledgePointId: 'binary-tree-postorder', knowledgePointName: '二叉树后序遍历', difficulty: 'easy', stem: '二叉树中序遍历访问节点的顺序是什么？', options: ['A. 根-左-右', 'B. 左-根-右', 'C. 左-右-根', 'D. 根-右-左'], source: 'demo' },
      { exerciseId: 'exercise-postorder-001', knowledgePointId: 'binary-tree-postorder', knowledgePointName: '二叉树后序遍历', difficulty: 'medium', stem: '二叉树后序遍历访问节点的顺序是什么？', options: ['A. 根-左-右', 'B. 左-根-右', 'C. 左-右-根', 'D. 根-右-左'], source: 'demo' }
    ] };
  }

  private static assessment(answers?: ExerciseAnswer[]): ExerciseSubmissionResult {
    const score: number = FixtureApiTransport.grade(answers);
    const newMastery: number = FixtureApiTransport.nextMastery(42, score);
    FixtureDemoStateStore.setMasteryScore(newMastery);
    const perKnowledge: Record<string, number> = {};
    perKnowledge['binary-tree-postorder'] = score;
    return { userId: ApiDefaults.DEMO_USER_ID, submissionId: ApiDefaults.DEMO_USER_ID + ':set-demo-binary-tree-001:fixture-submission', assessment: { score: score, perKnowledgeAccuracy: perKnowledge, errorTypes: score < 100 ? ['后序遍历顺序混淆'] : [], oldMastery: 42, suggestedNewMastery: newMastery }, masteryUpdate: { knowledgePointId: 'binary-tree-postorder', oldScore: 42, newScore: newMastery }, needReplan: score < 80, plan: FixtureApiTransport.plan(), planDiff: FixtureApiTransport.planDiff() };
  }

  private static planDiff(): PlanDiff {
    return { planId: 'plan-demo-001', oldVersion: 1, newVersion: 2, changedTasks: [{ taskId: 'task-postorder', knowledgePointId: 'binary-tree-postorder', durationMinutes: 45, change: '+15' }, { taskId: 'task-graph', knowledgePointId: 'graph-traversal', durationMinutes: 15, change: '-15' }], adjustmentReason: '二叉树后序遍历 mastery=58，低于巩固阈值60', triggerEvidence: ['evidence-demo-001'] };
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

  private static reset(): DemoResetResponse {
    const profile: ProfileResponse = FixtureApiTransport.profile();
    return { status: 'reset', userId: ApiDefaults.DEMO_USER_ID, profile: profile.profile ?? null, plan: FixtureApiTransport.plan(), traceId: 'trace-demo-001' };
  }
}
