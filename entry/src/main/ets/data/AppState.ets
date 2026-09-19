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
import {
  mockCurrentUser,
  mockCoursesList,
  mockHomeworkDDLs,
  mockCandidates
} from './MockData';
import { DateHelper } from '../utils/DateHelper';

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
  public courses: CourseInfo[] = [...mockCoursesList];
  public homeworkDDLs: HomeworkDDL[] = [...mockHomeworkDDLs];
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
    this.currentUser = {
      userId: user.userId,
      basicInfo: {
        name: user.nickname,
        grade: user.grade.length > 0 ? user.grade : this.currentUser.basicInfo.grade,
        major: this.currentUser.basicInfo.major
      },
      learningGoal: this.currentUser.learningGoal,
      time: this.currentUser.time,
      knowledge: this.currentUser.knowledge
    };
    this.authSource = source;
    this.authNickname = user.nickname;
    this.isSignedIn = source === 'local' || source === 'restored';
  }

  /**
   * 退出登录 → 回到演示身份。
   *
   * 必须**回到 demo-user**而不是清空：否则退出登录后首页会去查一个不存在的画像而报 404。
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
  }

  public startChatTask(taskName: string): void {
    this.activeChatTask = taskName;
  }

  public getChatTaskContext(): string {
    if (this.activeChatTask.length === 0) {
      return '由知学搭子为你准备';
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
    if (!this.isDataImported) {
      return '演示模式 · 3门课程 · 5项作业';
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

  public getHighPriorityCourse(): CourseInfo {
    if (this.courses.length === 0) {
      return mockCoursesList[0]; // 回退
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

  public getTodayPlanTasks(): LearningPlanTask[] {
    if (this.weeklyPlan === null) {
      return [];
    }
    const todayLabel: string = DateHelper.getTodayLabel();
    const todayFullLabel: string = DateHelper.getTodayLabel();
    return this.weeklyPlan.tasks.filter((task: LearningPlanTask) =>
      task.dateLabel.indexOf(todayLabel) !== -1
    );
  }

  public getPlanProgress(): number {
    if (this.weeklyPlan === null || this.weeklyPlan.tasks.length === 0) {
      return 0;
    }
    const completed: number = this.weeklyPlan.tasks.filter((task: LearningPlanTask) => task.status === 'completed').length;
    return Math.round(completed / this.weeklyPlan.tasks.length * 100);
  }

  public updatePlanTaskStatus(taskId: string, status: PlanTaskStatus): void {
    if (this.weeklyPlan === null) {
      return;
    }
    const task: LearningPlanTask | undefined = this.weeklyPlan.tasks.find((item: LearningPlanTask) => item.id === taskId);
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
    for (let index: number = 0; index < this.focusSessions.length; index++) {
      const session: FocusSession = this.focusSessions[index];
      todayMinutes += session.actualMinutes;
      totalCompletion += session.completionRate;
      const accumulated: number = courseMinutes.get(session.course) ?? 0;
      courseMinutes.set(session.course, accumulated + session.actualMinutes);
    }
    return {
      todayMinutes: todayMinutes,
      completionRate: this.focusSessions.length === 0 ? 0 : Math.round(totalCompletion / this.focusSessions.length),
      streakDays: this.focusSessions.length === 0 ? 0 : 3,
      courseMinutes: courseMinutes,
      recentSessions: this.focusSessions.slice(-7).reverse()
    };
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
}

export const appState: AppState = AppState.getInstance();
