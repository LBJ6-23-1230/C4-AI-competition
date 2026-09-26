import {
  CourseInfo,
  HomeworkDDL,
  LearningReview,
  PartnerMatch,
  StudySuggestion,
  UserProfile,
  WrongAnalysisResult,
  WrongQuestionImage,
  WorkflowContext,
  WorkflowStage,
  NavigationIntent,
  TaskPriority,
  WeaknessJudgment,
  MatchFeasibility,
  FocusTask,
  FocusSession,
  FocusSummary,
  LearningPlanTask,
  WeeklyLearningPlan,
  PlanTaskStatus
} from '../models/AgentModels';
import { ChatHandoff } from '../models/ChatModels';
import { ApiDefaults } from '../api/ApiDefaults';
import { AuthSource, AuthUser } from '../api/AuthModels';
// 契约形状的「用户看得见的那份计划」。用别名避免与 AgentModels 里的本地模型撞名 ——
// 两者的 `PlanTaskStatus` 取值集**不同**：契约是 pending/in_progress/completed，
// 本地还多 partial/deferred。
import {
  LearningPlan as VisiblePlan,
  PlanTask as VisiblePlanTask,
  PlanTaskStatus as VisiblePlanTaskStatus
} from '../api/ApiModels';
import {
  mockCurrentUser,
  mockCoursesList,
  mockHomeworkDDLs,
  mockCandidates
} from './MockData';
import { DateHelper } from '../utils/DateHelper';
import { ClientCache } from '../cache/ClientCache';

/**
 * AppState — 全局单例状态管理
 * 管理5层Agent工作流的所有状态数据
 *
 * 支持数据导入：用户可通过文件导入真实课程表和DDL，
 * 导入后 Agent 将基于真实数据分析而非模拟数据。
 */
export class AppState {
  private static instance: AppState;

  /* ========== 用户 & 课程数据 ========== */
  public currentUser: UserProfile = mockCurrentUser;
  // 用户数据默认必须为空。演示课程只能由显式“恢复演示数据”动作加载，
  // 不能在启动时伪装成已经导入的真实课程。
  public courses: CourseInfo[] = [];
  public homeworkDDLs: HomeworkDDL[] = [];
  public candidates: UserProfile[] = mockCandidates;

  /* ========== 数据导入状态 ========== */
  /** 是否已从外部文件导入真实数据（课程表或作业DDL） */
  public isDataImported: boolean = false;
  /** 导入的课程数量 */
  public importedCourseCount: number = 0;
  /** 导入的 DDL 数量 */
  public importedDDLCount: number = 0;

  /* ========== 登录态 ========== */
  /**
   * 是否处于**真实登录**态（游客 / 一键体验 / 离线 Fixture 都是 false）。
   * 注意：`currentUser.userId` 在游客态下是 `demo-user`，
   * 因此判断"是否登录"必须看这个标志，不能看 userId 是否为空。
   */
  public isSignedIn: boolean = false;
  /** 身份来源，用于「我的」页与首页标注。 */
  public authSource: AuthSource = 'guest';
  /** 当前展示用的昵称（游客态为演示昵称）。 */
  public authNickname: string = ApiDefaults.DEMO_USER_NAME;

  /* ========== 对话持久化 ========== */
  public chatMessages: string = '';  // JSON 序列化的消息列表
  public hasActiveChat: boolean = false;
  public pendingChatPrompt: string = '';  // 从其他页面跳回对话时的预填 prompt

  /* ========== 输入层数据 ========== */
  public wrongQuestionImages: WrongQuestionImage[] = [];

  /* ========== 理解层/行动层结果 ========== */
  public latestSuggestion: StudySuggestion | null = null;
  public latestWrongAnalysis: WrongAnalysisResult | null = null;
  public latestPartner: PartnerMatch | null = null;
  public latestReview: LearningReview | null = null;

  /* ========== 专注模式 ========== */
  public activeFocusTask: FocusTask | null = null;
  public focusResultDraft: FocusSession | null = null;
  public focusSessions: FocusSession[] = [];

  /* ========== 计划 Agent ========== */
  public weeklyPlan: WeeklyLearningPlan | null = null;

  /* ========== 判断层数据 ========== */
  public optimalTask: TaskPriority | null = null;
  public weaknessJudgments: WeaknessJudgment[] = [];
  public matchFeasibility: MatchFeasibility | null = null;

  /* ========== 工作流状态 ========== */
  public workflowContext: WorkflowContext = {
    currentStage: 'idle',
    lastAction: '',
    lastActionTime: '',
    completedStages: [],
    pendingActions: []
  };

  /* ========== 用户选择的图片URI ========== */
  public selectedImageUri: string = '';

  /* ========== 对话与任务页衔接 ========== */
  public activeChatTask: string = '';
  private chatHandoff: ChatHandoff | null = null;

  public static getInstance(): AppState {
    if (AppState.instance === undefined) {
      AppState.instance = new AppState();
    }
    return AppState.instance;
  }

  /* ========== 登录态 ========== */

  /**
   * 应用当前登录身份。
   *
   * 登录只做两件事：① 把 `currentUser.userId` 换成真实身份；② 记录登录来源供界面标注。
   * **不改动** `courses` / `homeworkDDLs` 等业务数据——那些由数据导入流程管理，
   * 与身份解耦，避免"登录一次把演示数据清空"这类副作用。
   *
   * 游客身份传入 `ApiDefaults.DEMO_USER_ID`，与后端演示数据天然对齐。
   *
   * `user` 允许为 null（防御式）：调用方若因异常拿到空用户，这里直接退化为体验身份，
   * 而不是把 null 写进 `currentUser` 引发后续一连串空指针。
   */
  public applyLogin(user: AuthUser | null, source: AuthSource): void {
    if (user === null) {
      this.applyLogout();
      return;
    }
    // ⚠️ 必须在覆盖 currentUser **之前**判断身份是否真的变了：
    // 变了才清账号维度状态，同身份重复登录（刷新 token / 冷启动恢复）不该把数据抖掉。
    const identityChanged: boolean = this.currentUser.userId !== user.userId;
    this.currentUser = {
      userId: user.userId,
      basicInfo: {
        name: user.nickname,
        // ⚠️ 服务端对"注册时跳过年级"的账号存的是**空串**；原实现回落成
        // `this.currentUser.basicInfo.grade` —— 而登出分支把这个值设成了
        // MockData 里写死的「大二」，于是**没选年级的新账号会凭空显示
        // 「在读年级：大二」**，并且 `Account.ets` 只在服务端值非空时才用它纠正
        // （`user.grade.length > 0`），永远纠不回来。
        // 这里如实留空，由页面显示「未设置」——不替用户编属性。
        grade: user.grade.length > 0 ? user.grade : '',
        major: this.currentUser.basicInfo.major
      },
      learningGoal: this.currentUser.learningGoal,
      time: this.currentUser.time,
      knowledge: this.currentUser.knowledge
    };
    this.authSource = source;
    this.authNickname = user.nickname;
    this.isSignedIn = source === 'local' || source === 'restored';

    // 缺陷修复：原实现只换 `currentUser.userId`，既不清 `ClientCache`
    // （身份盲区 → 账号会读到游客缓存的画像 / 计划 / 工作流 / trace），
    // 也不调 `resetAccountScopedState()`（`applyLogout` 调了、`applyLogin` 没调，
    // 于是游客的聊天记录与专注记录会串进账号）。
    ClientCache.bindIdentity(user.userId);
    if (identityChanged) {
      this.resetAccountScopedState();
    }
  }

  /**
   * 退出登录 → 回到演示身份。
   *
   * 必须**回到 demo-user**而不是清空：否则退出登录后首页会去查一个不存在的画像而报 404。
   *
   * ⚠️ 同时必须清掉**账号绑定的会话态**（对话记录、专注记录、分析结果）。
   * 只重置身份会让下一个登录的人看到上一个人的数据 —— 见
   * `resetAccountScopedState()` 的注释。
   */
  public applyLogout(): void {
    this.currentUser = {
      userId: ApiDefaults.DEMO_USER_ID,
      basicInfo: {
        name: ApiDefaults.DEMO_USER_NAME,
        grade: mockCurrentUser.basicInfo.grade,
        major: mockCurrentUser.basicInfo.major
      },
      learningGoal: mockCurrentUser.learningGoal,
      time: mockCurrentUser.time,
      knowledge: mockCurrentUser.knowledge
    };
    this.authSource = 'guest';
    this.authNickname = ApiDefaults.DEMO_USER_NAME;
    this.isSignedIn = false;
    // 与 `applyLogin` 对称：回到演示身份同样要让缓存跟着换归属，
    // 否则退出登录后游客会读到刚退出的那个账号的数据。
    ClientCache.bindIdentity(ApiDefaults.DEMO_USER_ID);
    this.resetAccountScopedState();
  }

  public startChatTask(taskName: string): void {
    this.activeChatTask = taskName;
  }

  public getChatTaskContext(): string {
    if (this.activeChatTask.length === 0) {
      return '由知学Mate为你准备';
    }
    return `正在完成：${this.activeChatTask}`;
  }

  public leaveChatTask(): void {
    this.activeChatTask = '';
  }

  public completeChatTask(summary: string, nextPrompt: string, actionLabel: string, targetPage: string): void {
    const handoff: ChatHandoff = {
      summary: summary,
      nextPrompt: nextPrompt,
      actionLabel: actionLabel,
      targetPage: targetPage
    };
    this.chatHandoff = handoff;
    this.activeChatTask = '';
  }

  public consumeChatHandoff(): ChatHandoff | null {
    const handoff: ChatHandoff | null = this.chatHandoff;
    this.chatHandoff = null;
    return handoff;
  }

  /* ========== 课程数据导入 ========== */

  /**
   * 导入课程表数据（替换现有课程列表）
   * 导入后 isDataImported 置为 true，Agent 将基于真实数据进行分析
   */
  public importCourses(newCourses: CourseInfo[]): void {
    if (newCourses.length === 0) {
      throw new Error('导入数据为空，请检查文件内容');
    }
    this.courses = newCourses;
    this.importedCourseCount = newCourses.length;
    this.isDataImported = true;
    this.advanceStage('input', '导入课程表数据');
  }

  /**
   * 导入作业 DDL 数据（替换现有 DDL 列表）
   */
  public importDDLs(newDDLs: HomeworkDDL[]): void {
    this.homeworkDDLs = newDDLs;
    this.importedDDLCount = newDDLs.length;
    this.isDataImported = true;
    this.advanceStage('input', '导入作业DDL数据');
  }

  /** 删除指定课程 */
  public removeCourse(courseId: string): void {
    const filtered: CourseInfo[] = [];
    for (let i = 0; i < this.courses.length; i++) {
      if (this.courses[i].courseId !== courseId) {
        filtered.push(this.courses[i]);
      }
    }
    this.courses = filtered;
    this.importedCourseCount = filtered.length;
  }

  /** 删除指定DDL */
  public removeDDL(ddlId: string): void {
    const filtered: HomeworkDDL[] = [];
    for (let i = 0; i < this.homeworkDDLs.length; i++) {
      if (this.homeworkDDLs[i].id !== ddlId) {
        filtered.push(this.homeworkDDLs[i]);
      }
    }
    this.homeworkDDLs = filtered;
    this.importedDDLCount = filtered.length;
  }

  /**
   * 追加课程（不替换已有数据）
   */
  public appendCourses(newCourses: CourseInfo[]): void {
    for (let i = 0; i < newCourses.length; i++) {
      this.courses.push(newCourses[i]);
    }
    this.importedCourseCount += newCourses.length;
    this.isDataImported = true;
  }

  /**
   * 追加 DDL（不替换已有数据）
   */
  public appendDDLs(newDDLs: HomeworkDDL[]): void {
    for (let i = 0; i < newDDLs.length; i++) {
      this.homeworkDDLs.push(newDDLs[i]);
    }
    this.importedDDLCount += newDDLs.length;
    this.isDataImported = true;
  }

  /**
   * 重置为模拟数据（用于演示回退）
   */
  public resetToMockData(): void {
    this.courses = [...mockCoursesList];
    this.homeworkDDLs = [...mockHomeworkDDLs];
    this.isDataImported = false;
    this.importedCourseCount = 0;
    this.importedDDLCount = 0;
    this.resetSession();
  }

  /**
   * 获取数据来源描述
   */
  public getDataSourceDescription(): string {
    if (!this.isDataImported && this.courses.length === 0 && this.homeworkDDLs.length === 0) {
      return '尚未导入课程与作业';
    }
    if (!this.isDataImported) {
      return `演示数据 · ${this.courses.length}门课程 · ${this.homeworkDDLs.length}项作业`;
    }
    const parts: string[] = [];
    if (this.importedCourseCount > 0) {
      parts.push(`${this.importedCourseCount}门课程`);
    }
    if (this.importedDDLCount > 0) {
      parts.push(`${this.importedDDLCount}项作业`);
    }
    return '已导入 · ' + (parts.length > 0 ? parts.join(' · ') : '数据已加载');
  }

  /* ========== 课程相关查询 ========== */

  public getHighPriorityCourse(): CourseInfo | null {
    if (this.courses.length === 0) {
      return null;
    }
    let highestCourse: CourseInfo = this.courses[0];
    for (let index: number = 1; index < this.courses.length; index++) {
      const course: CourseInfo = this.courses[index];
      if (course.exam.daysLeft < highestCourse.exam.daysLeft) {
        highestCourse = course;
      }
    }
    return highestCourse;
  }

  public getUrgentDDLs(): HomeworkDDL[] {
    return this.homeworkDDLs.filter((ddl: HomeworkDDL) => ddl.daysLeft <= 7);
  }

  public getDDLsByCourse(courseName: string): HomeworkDDL[] {
    return this.homeworkDDLs.filter((ddl: HomeworkDDL) => ddl.courseName === courseName);
  }

  public getWeaknessTags(): string[] {
    return this.currentUser.knowledge.weakness;
  }

  public getStrengthTags(): string[] {
    return this.currentUser.knowledge.strength;
  }

  /** 从其他页面跳回对话时预填 prompt */
  public setChatPrompt(prompt: string): void {
    this.pendingChatPrompt = prompt;
  }

  public setFocusTask(task: FocusTask): void {
    this.activeFocusTask = task;
  }

  public clearFocusTask(): void {
    this.activeFocusTask = null;
  }

  public setWeeklyPlan(plan: WeeklyLearningPlan): void {
    this.weeklyPlan = plan;
    this.advanceStage('output', 'Agent 已生成并更新本周学习计划');
  }

  public clearWeeklyPlan(): void {
    this.weeklyPlan = null;
  }

  /**
   * 今天的计划任务。
   *
   * ⚠️ 两处修正：
   *   1. 用 `dateLabel.indexOf(todayLabel) !== -1` 做**子串**匹配是错的 ——
   *      `getTodayLabel()` 给的是 `"2月1日"` 这种月日串，子串匹配会让它命中
   *      `"12月1日 周二"`，把 12 月 1 日的任务当成"今天"。改为按空格取日期段
   *      **精确**比较（`dateLabel` 的格式是 `"9月26日 周六"`）。
   *   2. 删掉声明后从未使用的 `todayFullLabel`。
   *
   * 注：当前没有页面调用本方法（属历史遗留）。保留并修正，是为了避免将来
   * 一旦被复用就按错误日期取任务。
   */
  public getTodayPlanTasks(): LearningPlanTask[] {
    if (this.weeklyPlan === null) {
      return [];
    }
    const todayLabel: string = DateHelper.getTodayLabel();
    return this.weeklyPlan.tasks.filter((task: LearningPlanTask) =>
      task.dateLabel.split(' ')[0] === todayLabel
    );
  }

  /**
   * 专注结算写入的**任务完成状态**，按任务 id 归档（overlay 用）。
   *
   * 为什么必须有这张表：App 里同时存在**两份计划**——
   *   · **用户看得见的那份**：接口返回的契约计划（联机为后端、离线为 Fixture），
   *     `taskId` 形如 `task-postorder`；
   *   · `weeklyPlan`：`LocalAgentService.generateWeeklyPlan` 本地生成的，
   *     `id` 形如 `agent-数据结构-0`。
   *
   * 两套 id 空间**互不相通**，而"首页主行动卡 → 专注 → 完成"沿路带下来的是
   * **契约 id**，于是完成状态永远匹配不到任何计划任务：「任务完成度」恒为 0%、
   * 「学习复盘」恒说"还没有完成任务"（实测复现）。
   *
   * 产品口径（已与产品确认）：**完成状态以用户看得见的那份计划为准**。
   * 后端没有回写 `task.status` 的接口，所以状态记在本地，读取时与计划做 overlay。
   */
  private taskStatusOverrides: Map<string, PlanTaskStatus> = new Map<string, PlanTaskStatus>();

  /**
   * 对外只读口径：这个计划任务算不算"已完成"。
   *
   * 计划页要据此把任务卡从「待执行」改成「已完成」—— 接口不会回写 `task.status`
   * （后端没有这个接口），完成状态只存在于本地，所以**页面必须问本地**，
   * 否则专注做完了、计划页还写着「待执行」，与「我的」里的完成度互相打架。
   */
  public isTaskCompleted(taskId: string, status: string): boolean {
    return this.isPlanTaskDone(taskId, status);
  }

  /** 判定任务是否完成：计划里标了 completed，或本地记录过 completed。 */
  private isPlanTaskDone(taskId: string, status: string): boolean {
    if (status === 'completed') {
      return true;
    }
    return this.taskStatusOverrides.get(taskId) === 'completed';
  }

  /** 已知计划里出现过的全部任务 id（用于判断一次标记有没有命中计划）。 */
  private knownPlanTaskIds(): string[] {
    const ids: string[] = [];
    const visible: VisiblePlan | null = ClientCache.getCurrentPlan();
    if (visible !== null) {
      visible.tasks.forEach((task: VisiblePlanTask) => ids.push(task.taskId));
    }
    if (this.weeklyPlan !== null) {
      this.weeklyPlan.tasks.forEach((task: LearningPlanTask) => ids.push(task.id));
    }
    return ids;
  }

  /**
   * 记录任务完成状态。**无论有没有命中计划都要记**——否则"先专注、后打开计划页"
   * 的顺序会让完成状态丢掉。
   *
   * @returns 是否在"已知的计划"里命中了这个 id（调用方据此决定提示文案，
   *          避免像原来那样没命中还报"计划进度已更新"）。
   */
  public markPlanTaskStatus(taskId: string | undefined, status: PlanTaskStatus): boolean {
    const key: string = (taskId ?? '').trim();
    if (key.length === 0) {
      return false;
    }
    this.taskStatusOverrides.set(key, status);
    return this.knownPlanTaskIds().indexOf(key) !== -1;
  }

  /**
   * 「任务完成度」。**优先用用户看得见的那份计划**（契约 / Fixture），
   * 它才是专注入口传下来的 id 所属的那一份；没有才回落到本地生成的计划。
   */
  public getPlanProgress(): number {
    const visible: VisiblePlan | null = ClientCache.getCurrentPlan();
    if (visible !== null && visible.tasks.length > 0) {
      const done: number = visible.tasks.filter(
        (task: VisiblePlanTask) => this.isPlanTaskDone(task.taskId, task.status)).length;
      return Math.round(done / visible.tasks.length * 100);
    }
    if (this.weeklyPlan === null || this.weeklyPlan.tasks.length === 0) {
      return 0;
    }
    const done: number = this.weeklyPlan.tasks.filter(
      (task: LearningPlanTask) => this.isPlanTaskDone(task.id, task.status)).length;
    return Math.round(done / this.weeklyPlan.tasks.length * 100);
  }

  /**
   * 「已完成」任务列表（学习复盘展示用）。与 `getPlanProgress()` 同一口径，
   * 保证"完成度"和"完成任务数"永远对得上。
   */
  public getCompletedPlanTasks(): LearningPlanTask[] {
    const visible: VisiblePlan | null = ClientCache.getCurrentPlan();
    if (visible !== null && visible.tasks.length > 0) {
      const done: VisiblePlanTask[] = visible.tasks.filter(
        (task: VisiblePlanTask) => this.isPlanTaskDone(task.taskId, task.status));
      const mapped: LearningPlanTask[] = [];
      done.forEach((task: VisiblePlanTask) => mapped.push(AppState.toDisplayTask(task)));
      return mapped;
    }
    if (this.weeklyPlan === null) {
      return [];
    }
    return this.weeklyPlan.tasks.filter(
      (task: LearningPlanTask) => this.isPlanTaskDone(task.id, task.status));
  }

  /** 把契约任务转成复盘页渲染用的本地形状（只填页面真正用到的字段）。 */
  private static toDisplayTask(task: VisiblePlanTask): LearningPlanTask {
    return {
      id: task.taskId,
      course: '专项学习',
      title: task.knowledgePointName,
      knowledgePoint: task.knowledgePointName,
      type: 'practice',
      dateLabel: '',
      plannedMinutes: task.durationMinutes,
      priorityScore: 0,
      priorityLabel: '',
      reason: '',
      completionCriteria: '',
      steps: [],
      status: 'completed',
      source: 'agent',
      canCollaborate: false
    };
  }

  public updatePlanTaskStatus(taskId: string, status: PlanTaskStatus): void {
    // 先记账：即使此刻计划还没加载，"完成"这件事也不能丢。
    const key: string = (taskId ?? '').trim();
    if (key.length === 0) {
      return;
    }
    this.taskStatusOverrides.set(key, status);
    if (this.weeklyPlan === null) {
      return;
    }
    const task: LearningPlanTask | undefined = this.weeklyPlan.tasks.find((item: LearningPlanTask) => item.id === key);
    if (task !== undefined) {
      task.status = status;
    }
  }

  public hasPendingWrongQuestionReview(course: string, knowledgePoint: string): boolean {
    if (this.weeklyPlan === null) {
      return false;
    }
    return this.weeklyPlan.tasks.some((task: LearningPlanTask) =>
      task.source === 'wrong_question' &&
      task.course === course &&
      task.knowledgePoint === knowledgePoint &&
      task.status !== 'completed'
    );
  }

  public addReviewTask(task: LearningPlanTask, message: string): boolean {
    if (this.weeklyPlan === null) {
      return false;
    }
    if (this.hasPendingWrongQuestionReview(task.course, task.knowledgePoint)) {
      this.weeklyPlan.adjustmentMessage = `“${task.knowledgePoint}”已在复习计划中，无需重复添加。`;
      return false;
    }
    this.weeklyPlan.tasks.unshift(task);
    this.weeklyPlan.adjustmentMessage = message;
    return true;
  }

  public hasActiveCollaborativeTask(taskId: string): boolean {
    if (this.weeklyPlan === null) {
      return false;
    }
    return this.weeklyPlan.tasks.some((task: LearningPlanTask) =>
      (task.id === taskId || task.id.startsWith(taskId + '-round-')) &&
      task.source === 'partner_match' && task.status !== 'completed'
    );
  }

  public hasCompletedCollaborativeTask(taskId: string): boolean {
    if (this.weeklyPlan === null) {
      return false;
    }
    return this.weeklyPlan.tasks.some((task: LearningPlanTask) =>
      (task.id === taskId || task.id.startsWith(taskId + '-round-')) &&
      task.source === 'partner_match' && task.status === 'completed'
    );
  }

  public nextCollaborativeTaskId(taskId: string): string {
    if (this.weeklyPlan === null) {
      return taskId;
    }
    const count: number = this.weeklyPlan.tasks.filter((task: LearningPlanTask) =>
      task.source === 'partner_match' &&
      (task.id === taskId || task.id.startsWith(taskId + '-round-'))
    ).length;
    return count === 0 ? taskId : `${taskId}-round-${count + 1}`;
  }

  public addCollaborativeTask(task: LearningPlanTask, message: string): boolean {
    if (this.weeklyPlan === null || this.hasActiveCollaborativeTask(task.id)) {
      if (this.weeklyPlan !== null) {
        this.weeklyPlan.adjustmentMessage = '该搭子的协同学习任务已在计划中，无需重复添加。';
      }
      return false;
    }
    this.weeklyPlan.tasks.unshift(task);
    this.weeklyPlan.adjustmentMessage = message;
    return true;
  }

  public clearCurrentWrongQuestionDraft(): void {
    this.selectedImageUri = '';
    this.latestWrongAnalysis = null;
  }

  public setFocusResultDraft(session: FocusSession): void {
    this.focusResultDraft = session;
  }

  public clearFocusResultDraft(): void {
    this.focusResultDraft = null;
  }

  public saveFocusSession(session: FocusSession): boolean {
    if (this.focusSessions.some((saved: FocusSession) => saved.taskId === session.taskId)) {
      return false;
    }
    this.focusSessions.push(session);
    return true;
  }

  public getFocusSummary(): FocusSummary {
    const courseMinutes: Map<string, number> = new Map();
    let todayMinutes: number = 0;
    let totalCompletion: number = 0;
    const todayKey: string = DateHelper.todayKey();
    // 收集"有专注记录"的日期键，用于计算连续天数。
    const studyDays: Set<string> = new Set<string>();
    for (let index: number = 0; index < this.focusSessions.length; index++) {
      const session: FocusSession = this.focusSessions[index];
      totalCompletion += session.completionRate;
      const accumulated: number = courseMinutes.get(session.course) ?? 0;
      courseMinutes.set(session.course, accumulated + session.actualMinutes);
      // ⚠️ `todayMinutes` 必须**按本地日期过滤**。
      // 原实现对所有历史会话无条件 `+=`，于是"今日专注 X 分钟"实际是"累计专注"，
      // 跨天常驻进程下会把昨天的分钟算进今天，
      // 而它还是 ProactiveSurfaceService / Index.loadProactiveDecision 的输入 —— 错误会扩散。
      const dayKey: string = DateHelper.localDateKey(session.endedAt);
      if (dayKey.length === 0) {
        continue;   // 时间戳无法解析：跳过，不猜成今天
      }
      studyDays.add(dayKey);
      if (dayKey === todayKey) {
        todayMinutes += session.actualMinutes;
      }
    }
    return {
      todayMinutes: todayMinutes,
      completionRate: this.focusSessions.length === 0 ? 0 : Math.round(totalCompletion / this.focusSessions.length),
      streakDays: AppState.countStreakDays(studyDays, todayKey),
      courseMinutes: courseMinutes,
      recentSessions: this.focusSessions.slice(-7).reverse()
    };
  }

  /**
   * 连续学习天数：从今天（或昨天）往回数，遇到第一个断档就停。
   *
   * ⚠️ 原实现是 `streakDays: this.focusSessions.length === 0 ? 0 : 3`
   * —— **一个写死的字面量 3**。只要做过一次专注，首页/我的/学习记录
   * 三处都会显示"连续学习 3 天"，且与真实记录无关。评委追问"这个 3 怎么算的"
   * 无法回答，属于**展示伪造指标**。
   *
   * 口径说明（刻意允许"昨天"作为起点）：今天还没学习不该立刻把连续天数清零，
   * 否则用户每天早上打开 App 都会看到 0，激励效果反而变差。
   */
  private static countStreakDays(studyDays: Set<string>, todayKey: string): number {
    if (studyDays.size === 0) {
      return 0;
    }
    let cursor: string = todayKey;
    if (!studyDays.has(cursor)) {
      // 今天还没学：允许从昨天起算
      const yesterdayKey: string = AppState.shiftDayKey(cursor, -1);
      if (!studyDays.has(yesterdayKey)) {
        return 0;
      }
      cursor = yesterdayKey;
    }
    let streak: number = 0;
    while (studyDays.has(cursor)) {
      streak++;
      cursor = AppState.shiftDayKey(cursor, -1);
    }
    return streak;
  }

  /** 把 `YYYY-MM-DD` 键平移若干天，返回新的键。 */
  private static shiftDayKey(key: string, deltaDays: number): string {
    const base: Date = new Date(`${key}T00:00:00`);
    if (isNaN(base.getTime())) {
      return '';
    }
    base.setDate(base.getDate() + deltaDays);
    return `${base.getFullYear()}-${DateHelper.pad(base.getMonth() + 1)}-${DateHelper.pad(base.getDate())}`;
  }

  /* ========== 图片管理 ========== */

  public addWrongQuestionImage(uri: string, fileName: string): void {
    const image: WrongQuestionImage = {
      imageUri: uri,
      fileName: fileName,
      uploadTime: new Date().toLocaleString()
    };
    this.wrongQuestionImages.push(image);
    this.selectedImageUri = uri;
  }

  public getLatestImage(): WrongQuestionImage | null {
    if (this.wrongQuestionImages.length === 0) {
      return null;
    }
    return this.wrongQuestionImages[this.wrongQuestionImages.length - 1];
  }

  /* ========== 工作流管理 ========== */

  public advanceStage(stage: WorkflowStage, action: string): void {
    this.workflowContext.currentStage = stage;
    this.workflowContext.lastAction = action;
    this.workflowContext.lastActionTime = new Date().toLocaleString();
    if (this.workflowContext.completedStages.indexOf(stage) === -1) {
      this.workflowContext.completedStages.push(stage);
    }
  }

  public hasCompleted(stage: WorkflowStage): boolean {
    return this.workflowContext.completedStages.indexOf(stage) !== -1;
  }

  /** 获取当前可用的导航选项 */
  public getAvailableActions(): NavigationIntent[] {
    const actions: NavigationIntent[] = ['back_to_hub'];

    if (this.wrongQuestionImages.length > 0 && this.latestWrongAnalysis !== null) {
      actions.push('view_tags');
    }
    if (this.latestPartner === null) {
      actions.push('find_partner');
    }
    if (this.latestSuggestion !== null) {
      actions.push('view_study_plan');
    }
    if (this.latestReview !== null) {
      actions.push('view_review');
    }
    if (this.courses.length > 0) {
      actions.push('view_courses');
    }
    if (this.wrongQuestionImages.length === 0 || this.latestWrongAnalysis === null) {
      actions.push('analyze_wrong_question');
    }

    return actions;
  }

  /** 重置学习会话 */
  public resetSession(): void {
    this.latestSuggestion = null;
    this.latestWrongAnalysis = null;
    this.latestPartner = null;
    this.latestReview = null;
    this.optimalTask = null;
    this.weaknessJudgments = [];
    this.matchFeasibility = null;
    this.wrongQuestionImages = [];
    this.selectedImageUri = '';
    this.weeklyPlan = null;
    this.activeChatTask = '';
    this.chatHandoff = null;
    this.workflowContext = {
      currentStage: 'idle',
      lastAction: '',
      lastActionTime: '',
      completedStages: [],
      pendingActions: []
    };
  }

  /**
   * 清空**与具体账号绑定**的会话态。
   *
   * 与 `resetSession()` 的分工：
   *   `resetSession()` 清的是"本次分析结果"（画像/建议/搭子/周计划等），
   *   在页面内换任务时也可能调用；
   *   本方法清的是**对话记录与专注记录**这类"属于某个人"的数据，
   *   只在**身份变更**（登出 / 切换账号）时调用。
   *
   * ⚠️ 为什么必须有这个方法：原实现里登出只重置身份四件套，
   * `chatMessages` / `hasActiveChat` / `focusSessions` / `pendingChatPrompt`
   * 全部原样保留，而 `ChatMain.aboutToAppear` 会用
   * `appState.hasActiveChat && appState.chatMessages.length > 0` 恢复对话历史 ——
   * 于是 **A 账号退出、B 账号登录后，B 会看到 A 的聊天记录与专注时长**。
   * 这是可复现的跨账号数据泄露。
   */
  public resetAccountScopedState(): void {
    this.chatMessages = '';
    this.hasActiveChat = false;
    this.pendingChatPrompt = '';
    this.focusSessions = [];
    this.activeFocusTask = null;
    this.clearFocusResultDraft();
    // 任务完成状态是**账号维度**的：不清会让下一个登录的人看到上一个人的
    // "已完成"任务（与 focusSessions / courses 同一类跨身份串数据）。
    this.taskStatusOverrides.clear();
    // 课程和 DDL 目前是本地内存数据，没有服务端账号归属。切换身份时若保留，
    // 会让账号看到游客导入的内容（反之亦然），形成明显的跨身份串数据。
    this.courses = [];
    this.homeworkDDLs = [];
    this.isDataImported = false;
    this.importedCourseCount = 0;
    this.importedDDLCount = 0;
    this.resetSession();
  }
}

export const appState: AppState = AppState.getInstance();
