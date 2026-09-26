import router from '@ohos.router';
import { appState } from '../data/AppState';
import { FocusTask, LearningPlanTask, WeeklyLearningPlan } from '../models/AgentModels';
import { LocalAgentService } from '../services/LocalAgentService';
import { DateHelper } from '../utils/DateHelper';
import { ChatNavigation } from '../services/ChatNavigation';
import { AIFloatButton } from '../components/AIFloatButton';
import { FactorBreakdownCard } from '../components/FactorBreakdownCard';
import { AgentApiClient, ApiClientConfig } from '../api/AgentApiClient';
import { ApiDefaults } from '../api/ApiDefaults';
import { LearningPlan, PlanTask, ProactiveResponse, WorkflowResponse, WorkflowStatusResponse } from '../api/ApiModels';
import { ClientCache } from '../cache/ClientCache';
import { WorkflowViewModel } from '../viewmodels/WorkflowViewModel';
import { ApiDisplayFormatter } from '../utils/ApiDisplayFormatter';
import { PlanViewModel } from '../viewmodels/PlanViewModel';
import { ProactiveViewModel } from '../viewmodels/ProactiveViewModel';
import { common } from '@kit.AbilityKit';
import { LearningCardService } from '../services/LearningCardService';
import { WorkflowSessionStore } from '../cache/WorkflowSessionStore';
import { AuthClient } from '../api/AuthClient';
import { AuthStore } from '../api/AuthStore';

@Entry
@Component
struct Index {
  @State refreshKey: number = 0;
  @State isWorkflowRefreshing: boolean = false;
  @State isAgentPlanLoading: boolean = false;
  @State agentPlan: LearningPlan | null = null;
  @State agentPlanMessage: string = '';
  @State proactiveDecision: ProactiveResponse | null = null;
  @State proactiveMessage: string = '';
  @State isProactiveLoading: boolean = false;
  /** 切换身份进行中（防连点重复吊销会话）。 */
  @State isSwitchingIdentity: boolean = false;
  /** 当前标签页：0 对话（回对话页）/ 1 我的智能体 / 2 学习 / 3 我的。 */
  @State activeTab: number = 1;
  /** 智能体页的分类筛选，默认「全部」。 */
  @State agentFilter: string = '全部';
  /** 多入口智能体的选择浮层。 */
  @State showRouteSheet: boolean = false;
  @State pendingAgent: AgentSpec | null = null;
  private workflowViewModel: WorkflowViewModel = new WorkflowViewModel();
  private planViewModel: PlanViewModel = new PlanViewModel();
  private proactiveViewModel: ProactiveViewModel = new ProactiveViewModel();
  private workflowRequestVersion: number = 0;
  private planRequestVersion: number = 0;
  private proactiveRequestVersion: number = 0;
  private isPageActive: boolean = false;

  aboutToAppear(): void {
    this.isPageActive = true;
    this.applyInitialTab();
    this.ensurePlan();
    this.refreshKey++;
    this.bootstrapWorkflow();
    this.loadProactiveDecision();
  }

  /**
   * 读取路由参数 `initialTab`，支持从对话页底部标签直达指定标签。
   *
   * 为什么需要：智能体页与学习页都在本页的不同标签里，
   * 对话页点「智能体」时若只 `replaceUrl('pages/Index')`，
   * 会因为本页默认标签是 1 而永远只看到智能体页、看不到学习页。
   * 带参数跳转后，落地标签由调用方决定。
   */
  private applyInitialTab(): void {
    try {
      const params: Record<string, Object> = router.getParams() as Record<string, Object>;
      if (params === undefined || params === null) {
        return;
      }
      const value: Object | undefined = params['initialTab'] as Object | undefined;
      if (typeof value === 'number' && value >= 0 && value <= 3) {
        this.activeTab = value as number;
      }
    } catch (error) {
      // 无参数（正常启动）时保持默认标签，不抛错
    }
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.workflowRequestVersion++;
    this.planRequestVersion++;
    this.proactiveRequestVersion++;
    this.isWorkflowRefreshing = false;
  }

  /**
   * 判断这份 proactive 决策是否真的"有可执行的动作"。
   *
   * 后端在静默情形（专注会话进行中、或未命中任何触发条件）会返回
   * `action.type='none'` + 空 title/hint。这种结果**不该覆盖桌面学习卡** ——
   * 否则用户桌面上的卡片会变成空任务或"不打扰"这类无意义文案。
   *
   * 首页仍然照常展示 `cardData` / `reason`（那是"推荐做什么"），
   * 只是不把它写进卡片。
   */
  private hasActionableDecision(decision: ProactiveResponse): boolean {
    if (decision.action === undefined || decision.action === null) {
      return false;
    }
    return decision.action.type !== 'none' && decision.title.trim().length > 0;
  }

  private async loadProactiveDecision(): Promise<void> {
    this.isProactiveLoading = true;
    this.proactiveMessage = '';
    const requestVersion: number = ++this.proactiveRequestVersion;
    // ⚠️ 不要用 `?? 30` 编一个倒计时：没有课程/考试日期时**如实传 undefined**，
    // 由 `ProactiveViewModel.buildRequest` 决定不下发该字段（后端会跳过考试类判断）。
    // 原来编的 30 会让卡片文案写成"考试剩 30 天（紧迫度贡献 0.000）"，
    // 与计划页的后端口径（5 天 → 0.83）互相矛盾。
    const highPriorityCourse = appState.getHighPriorityCourse();
    const daysLeft: number | undefined = highPriorityCourse !== null
      ? highPriorityCourse.exam.daysLeft : undefined;
    const recentSessions = appState.getFocusSummary().recentSessions;
    const lastStudyAt: string | undefined = recentSessions.length > 0 ? recentSessions[0].endedAt : undefined;
    // `foreground` 传 **false** —— 这一点是修过的缺陷。
    //
    // 原先传 `true`，后端 `agent/proactive.py` 会直接返回静默结果
    // （`action.type='none'`、`title=''`、`hint=''`）。后果有两个：
    //   ① `startProactiveTask()` 与 `isActionReady()` 的第一个分支**变成死代码**；
    //   ② 那个空结果会被 `LearningCardService.saveDecision()` 存成学习卡，
    //      用户在桌面上看到一句"用户当前前台使用应用，暂不打扰"。
    //
    // 语义上也本就不该传 true：`shouldNotify` 回答的是"**要不要发系统通知**"，
    // 而首页只关心"**推荐做什么**"。前台展示与通知投递是两件事 ——
    // 通知投递由 `ProactiveSurfaceService`（App 进后台时）负责。
    const state = await this.proactiveViewModel.load(
      appState.currentUser.userId, daysLeft, false,
      appState.activeFocusTask !== null && appState.focusResultDraft === null,
      lastStudyAt);
    if (!this.isPageActive || requestVersion !== this.proactiveRequestVersion) return;
    this.proactiveDecision = state.decision;
    this.proactiveMessage = state.errorMessage;
    if (state.decision !== null && this.hasActionableDecision(state.decision)) {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      void LearningCardService.saveDecision(context, state.decision);
    }
    this.isProactiveLoading = false;
  }

  private async loadAgentPlan(forceRefresh: boolean = true): Promise<void> {
    this.isAgentPlanLoading = true;
    this.agentPlanMessage = '';
    const requestVersion: number = ++this.planRequestVersion;
    const state = await this.planViewModel.load(forceRefresh);
    if (!this.isPageActive || requestVersion !== this.planRequestVersion) return;
    this.agentPlan = state.plan;
    this.agentPlanMessage = state.errorMessage;
    this.isAgentPlanLoading = false;
  }

  private isFixture(): boolean {
    return AgentApiClient.getConfig().useFixture;
  }

  private currentAgentTask(): PlanTask | null {
    if (this.agentPlan === null || this.agentPlan.tasks.length === 0) return null;
    for (let index: number = 0; index < this.agentPlan.tasks.length; index++) {
      if (this.agentPlan.tasks[index].status !== 'completed') return this.agentPlan.tasks[index];
    }
    return null;
  }

  private startAgentTask(task: PlanTask): void {
    appState.setFocusTask({
      course: '专项学习',
      task: task.knowledgePointName,
      plannedMinutes: task.durationMinutes,
      source: 'agent',
      mode: 'normal',
      timerType: 'countdown',
      planTaskId: task.taskId
    } as FocusTask);
    router.pushUrl({ url: 'pages/FocusSetup' });
  }

  private startProactiveTask(): void {
    const decision: ProactiveResponse | null = this.proactiveDecision;
    if (decision === null || decision.action.type !== 'focus') return;
    appState.setFocusTask({
      course: '数据结构',
      task: decision.cardData.taskName ?? '二叉树后序遍历',
      plannedMinutes: decision.action.preset.durationMinutes ?? decision.cardData.durationMinutes ?? 45,
      source: 'agent',
      mode: 'normal',
      timerType: 'countdown',
      planTaskId: decision.action.preset.taskId
    } as FocusTask);
    router.pushUrl({ url: 'pages/FocusSetup' });
  }

  private async bootstrapWorkflow(): Promise<void> {
    if (this.isWorkflowRefreshing) {
      return;
    }
    this.isWorkflowRefreshing = true;
    const requestVersion: number = ++this.workflowRequestVersion;
    let workflow: WorkflowResponse | null = ClientCache.getWorkflow();
    let created: boolean = false;
    if (workflow === null) {
      workflow = await this.workflowViewModel.start(
        appState.currentUser.learningGoal.goal,
        appState.currentUser.userId
      );
      // ⚠️ 建完必须**持久化**这个会话。
      //
      // 原来只有 `StudyTags`（启动诊断那条路径）会 `WorkflowSessionStore.save`，
      // 而这里是首页每次冷启动都会走的路径：它建完就丢，
      // 于是**每次启动都新造一个 workflow + 一个空 trace，且永远不会被复用** ——
      // 运行库里 workflows/traces 单调增长（实测 45 个计划、19 条轨迹里
      // 相当一部分是这么攒出来的）。存下来之后冷启动就能恢复同一个会话。
      if (workflow !== null) {
        const context: common.UIAbilityContext =
          this.getUIContext().getHostContext() as common.UIAbilityContext;
        WorkflowSessionStore.save(context, workflow, appState.currentUser.userId);
      }
      created = workflow !== null;
    }
    if (workflow !== null) {
      if (created) {
        await this.workflowViewModel.runUntilComplete(1);
      } else {
        await this.workflowViewModel.refreshStatus(true);
      }
      // ★ 自愈：本地缓存的会话在服务端已不存在（典型触发：刚跑过 `demo/reset`，
      //   它会把演示名下的 workflows 清掉）。
      //
      //   光清 `ClientCache` 不够 —— `WorkflowSessionStore` 里还存着同一个 id，
      //   下次冷启动又会把它读回来，用户就永远停在「workflow not found + 重试」
      //   （而重试**永远不会成功**）。这里连持久化一起清，并立刻新建一个会话，
      //   用户不必自己点重试。实测触发路径：重置演示数据 → 回首页。
      if (this.workflowViewModel.wasSessionStale()) {
        // 会话失效：`WorkflowViewModel` 内部**已经**清掉 `ClientCache` 并新建了一个，
        // 这里只负责把**持久化**那份也换掉 —— 否则下次冷启动又会把死 id 读回来。
        // ⚠️ 不要再调 `start()`：那会多建一个用不上的 workflow。
        const staleContext: common.UIAbilityContext =
          this.getUIContext().getHostContext() as common.UIAbilityContext;
        WorkflowSessionStore.clear(staleContext);
        const fresh: WorkflowResponse | null = ClientCache.getWorkflow();
        if (fresh !== null) {
          WorkflowSessionStore.save(staleContext, fresh, appState.currentUser.userId);
        }
      }
    }
    // ⚠️ 这里**不能**加 `if (!this.isFixture())` 的门槛。
    //
    // 原来只在联机模式加载计划，于是离线模式下 `ClientCache` 里没有"用户看得见的那份
    // 计划"，而首页主行动卡带下来的 taskId 是**契约 id**（`task-postorder`）、
    // `appState.weeklyPlan` 里却是本地 id（`agent-数据结构-0`）—— 专注完成后
    // 完成状态匹配不到任何任务，「任务完成度」恒 0%、复盘恒说"还没有完成任务"
    // （文档 P0-2，复现路径正是离线模式）。
    // 离线模式下 `AgentApiClient.getCurrentPlan()` 走 Fixture 传输层，不发网络请求。
    await this.loadAgentPlan(true);
    if (!this.isPageActive || requestVersion !== this.workflowRequestVersion) {
      return;
    }
    this.isWorkflowRefreshing = false;
    this.refreshKey++;
  }

  private ensurePlan(): void {
    if (!this.isFixture()) return;
    if (appState.weeklyPlan === null) {
      appState.setWeeklyPlan(LocalAgentService.generateWeeklyPlan(
        appState.courses, appState.homeworkDDLs, appState.currentUser
      ));
    }
  }

  /**
   * 取当前周计划，**保证非空**。
   *
   * ⚠️ 原实现是 `ensurePlan(); return appState.weeklyPlan!;` —— 这是运行时炸弹：
   * `ensurePlan()` 在**联机模式直接 return**（`weeklyPlan` 只由本地生成路径写入，
   * 服务端从不写它），所以联机模式下 `weeklyPlan` 一直是 `null`，
   * `!` 只是让类型检查闭嘴，运行时照样抛 `Cannot read property 'tasks' of null`。
   *
   * 触发路径：联机模式 + 后端不可达 → 首页主行动卡走「先做一组快速诊断」兜底
   * → `onPrimaryAction()` 求值 `primaryTask()` → 本方法 → 崩溃，
   * 用户点首页主按钮直接闪退（`openExercisePractice()` 永远执行不到）。
   *
   * 现在返回一份**结构合法的空计划**（tasks 为空数组、decisionTrace 字段齐全），
   * 让上层按"今天没有排定任务"走正常兜底，而不是崩溃。
   */
  private plan(): WeeklyLearningPlan {
    this.ensurePlan();
    const current: WeeklyLearningPlan | null = appState.weeklyPlan;
    if (current !== null) {
      return current;
    }
    return {
      weekLabel: '本周',
      tasks: [],
      decisionTrace: {
        inputSummary: '',
        urgencyReason: '',
        weaknessReason: '',
        timeReason: '',
        recommendation: '',
        updatedAt: ''
      },
      adjustmentMessage: ''
    } as WeeklyLearningPlan;
  }

  private todayTasks(): LearningPlanTask[] {
    const todayLabel: string = DateHelper.getTodayLabel();
    return this.plan().tasks.filter((task: LearningPlanTask) =>
      task.dateLabel.indexOf(todayLabel) !== -1 && task.status !== 'completed'
    );
  }

  private primaryTask(): LearningPlanTask | null {
    const today: LearningPlanTask[] = this.todayTasks();
    return today.length > 0 ? today[0] : null;
  }

  private startTask(task: LearningPlanTask): void {
    appState.setFocusTask({
      course: task.course,
      task: task.title,
      plannedMinutes: task.plannedMinutes,
      source: 'agent',
      mode: 'normal',
      timerType: 'countdown',
      planTaskId: task.id
    } as FocusTask);
    router.pushUrl({ url: 'pages/FocusSetup' });
  }

  private openHistory(): void {
    router.pushUrl({ url: 'pages/LearningHistory' });
  }

  // ==========================================================================
  // 首页信息架构（2026-09-18 重构）
  //
  // 设计初衷（docs/前端README.md 5 层工作流）：Agent 的第 3 层「判断层」要挑出
  // **最优**的一步，第 4/5 层把它变成可执行行动。所以首页的正确形态是
  // **「一个最优下一步」+「其他一切收纳」**，而不是把所有功能平铺成并列入口。
  //
  // 重构前的问题：10 个按钮 / 18 个可点区域 / 9 个跳转目标平铺在一起，
  // 用户点进来不知道该干嘛；底部"标签栏"其实是 4 个跳转快捷键（active 写死 true），
  // 「我的」居然跳到学习记录页，点击结果完全不可预期。
  //
  // 重构后：4 个区块 + 真实标签栏，且**身份标签与"我的"标签指向同一个页面**。
  // ==========================================================================

  /** 页头：身份标签可点进「我的」，与底部标签栏指向一致（原来一个进 Account、一个进 LearningHistory）。 */
  /** 页头标题：与底部标签一一对应（0 号「对话」已跳走到 ChatMain，不会在此出现）。 */
  private headerTitle(): string {
    if (this.activeTab === 1) return '我的智能体';
    if (this.activeTab === 2) return '学习';
    return '我的';
  }

  /**
   * 底部标签栏。
   *
   * ⚠️ **必须写成无参 `@Builder`**，且高亮状态在 Builder 内部**直接读 `this.activeTab`**。
   *
   * 原因：ArkTS 的 `@Builder` 函数参数是**按值传递**的，参数变化不会触发该 Builder
   * 重新求值（只有组件所在范围整体重建时才会刷新）。所以
   * `BottomNavItem('⌂', '首页', this.activeTab === 0, ...)` 这种写法里，
   * `active` 是**初次渲染时算好的布尔值**，切换标签后高亮永远停在"首页"——
   * 页面内容已经切走了，标签却还加粗在首页。这正是本次修掉的 bug。
   *
   * 改成无参 Builder 后，`this.activeTab` 是 `@State`，其变化会驱动
   * `TabBar` 所在范围重建，从而正确刷新每一项的高亮。
   */
  /**
   * 能力卡片（对齐参考设计图3）。
   *
   * 每张卡：图标 + 分类标签 / 名称 / 一句话说明 / 可用状态 + 「使用」。
   * 卡片只接收**静态**的 AgentSpec（常量），不含状态，故不存在
   * 「@Builder 参数不触发重渲染」的问题。
   */
  @Builder
  AgentCard(item: AgentSpec) {
    Column({ space: 10 }) {
      Row() {
        Text(item.icon).fontSize(18).fontColor('#2563EB')
          .width(34).height(34).textAlign(TextAlign.Center)
          .borderRadius(9).backgroundColor('#EFF6FF')
        Blank()
        Text(item.category).fontSize(10).fontColor('#475467')
          .backgroundColor('#F1F5F9').borderRadius(7)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      }.width('100%')

      Text(item.name).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A')
        .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })

      // 职能一句话：比 desc 更短，回答"这个智能体替我干什么"
      Text(item.role).fontSize(11.5).fontWeight(FontWeight.Medium).fontColor('#2563EB')
        .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(item.desc).fontSize(11).fontColor('#64748B').lineHeight(16)
        .width('100%').height(48).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })

      Row() {
        Row({ space: 4 }) {
          Text('●').fontSize(8).fontColor('#10B981')
          Text(item.ready ? '可用' : '需联网').fontSize(10).fontColor('#10B981')
        }
        Blank()
        Text(item.routes.length > 1 ? `${item.routes.length} 个入口 ↗` : '使用 ↗')
          .fontSize(12).fontWeight(FontWeight.Bold).fontColor('#2563EB')
      }.width('100%')
    }
    .width('48.5%').padding(14).margin({ bottom: 12 })
    .backgroundColor('#FFFFFF').borderRadius(14)
    .border({ width: 1, color: '#EAECF0' })
    .onClick(() => this.invokeAgent(item))
  }

  /** 「学习」标签里的一行入口。 */
  @Builder
  PanelRow(icon: string, title: string, desc: string, target: string) {
    Row({ space: 12 }) {
      Text(icon).fontSize(15).fontColor('#2563EB')
        .width(30).height(30).textAlign(TextAlign.Center)
        .borderRadius(15).backgroundColor('#EFF6FF')
      Column({ space: 2 }) {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#1F2937')
        Text(desc).fontSize(11).fontColor('#667085').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('›').fontSize(16).fontColor('#98A2B3')
    }
    .width('100%').padding(14).backgroundColor('#FFFFFF').borderRadius(14)
    .border({ width: 1, color: '#EAECF0' })
    .onClick(() => router.pushUrl({ url: target }))
  }

  /** 引导卡（学习 / 我的 标签顶部）。 */
  @Builder
  PanelCard(title: string, desc: string, buttonText: string, target: string) {
    Column({ space: 12 }) {
      Text(title).fontSize(17).fontWeight(FontWeight.Bold).fontColor('#0F172A').width('100%')
      Text(desc).fontSize(12.5).fontColor('#64748B').lineHeight(19).width('100%')
      Button(buttonText)
        .width('100%').height(46).fontSize(14).fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(12)
        .onClick(() => router.pushUrl({ url: target }))
    }
    .width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(16)
    .border({ width: 1, color: '#EAECF0' })
  }

  /** 当前唯一推荐行动。首页前台展示不等同于系统通知，因此不依赖 shouldNotify。 */
  @Builder
  PrimaryActionCard() {
    Column({ space: 10 }) {
      Text(this.perceptionLine()).fontSize(11.5).fontColor('#64748B').width('100%')
      if (this.proactiveDecision !== null) {
        Text(this.proactiveDecision!.cardData.taskName ?? this.proactiveDecision!.title)
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#0F172A').width('100%')
        Text(this.proactiveDecision!.reason.length > 0
          ? this.proactiveDecision!.reason : this.proactiveDecision!.body)
          .fontSize(12.5).fontColor('#475467').lineHeight(19).width('100%')
      } else if (this.currentAgentTask() !== null) {
        Text(this.currentAgentTask()!.knowledgePointName)
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#0F172A').width('100%')
        Text('这是 Agent 当前计划中的下一项未完成任务。')
          .fontSize(12.5).fontColor('#475467').lineHeight(19).width('100%')
      } else {
        Text('先做一组快速诊断').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#0F172A').width('100%')
        Text(this.proactiveMessage.length > 0 ? this.proactiveMessage : '用一组练习确定当前薄弱点，再生成下一步计划。')
          .fontSize(12.5).fontColor('#475467').lineHeight(19).width('100%')
      }
      Button(this.isActionReady() ? '开始当前任务' : '开始诊断')
        .width('100%').height(46).fontSize(14).fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(12)
        .onClick(() => this.onPrimaryAction())
    }
    .width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(16)
    .border({ width: 1, color: '#BFDBFE' })
  }

  /** 「我的」标签的统计块（任务完成度 / 专注次数等）。 */
  @Builder
  StatCard(value: string, label: string) {
    Column({ space: 4 }) {
      Text(value).fontSize(20).fontWeight(FontWeight.Bold).fontColor('#0F172A')
      Text(label).fontSize(11).fontColor('#64748B').textAlign(TextAlign.Center)
    }
    .layoutWeight(1).padding({ top: 14, bottom: 14 })
    .backgroundColor('#FFFFFF').borderRadius(14)
    .border({ width: 1, color: '#EAECF0' })
  }

  /** 页头副标题：按标签切换，说明这一页能做什么。 */
  private headerSubtitle(): string {
    if (this.activeTab === 1) return '多智能体助学团：诊断 → 规划 → 练习 → 测评。';
    // 学习标签只做"任务从哪来、时间怎么安排"，能力类入口一律去「智能体」页，避免重复。
    if (this.activeTab === 2) return '上传作业 DDL、安排专注任务。';
    return '账号与密码管理、学习数据、我的搭子。';
  }

  /** 按分类过滤能力卡；'全部' 返回全部。 */
  private filteredAgents(): AgentSpec[] {
    if (this.agentFilter === '全部') {
      return AGENT_SPECS;
    }
    return AGENT_SPECS.filter((item: AgentSpec) => item.category === this.agentFilter);
  }

  /**
   * 调用某个智能体。
   *
   * **不改任何 Agent 行为**：一个智能体可能对应多个既有页面（`routes`），
   * 这里只负责把用户送到对应页面；所有分析、判分、重规划逻辑仍由后端原有代码完成。
   *
   * 交互取舍：单入口直接跳；多入口用一个轻量 ActionSheet 让用户选，
   * 避免"点一下不知道该去哪"。
   */
  private invokeAgent(item: AgentSpec): void {
    if (item.routes.length === 0) {
      return;
    }
    if (item.routes.length === 1) {
      this.goRoute(item.routes[0]);
      return;
    }
    this.pendingAgent = item;
    this.showRouteSheet = true;
  }

  /** 执行一个入口跳转：有 prompt 的走对话（预填问题），否则直达页面。 */
  private goRoute(route: AgentRoute): void {
    this.showRouteSheet = false;
    if (route.prompt.length > 0) {
      appState.setChatPrompt(route.prompt);
      router.pushUrl({ url: 'pages/ChatMain' });
      return;
    }
    router.pushUrl({ url: route.target });
  }

  /** 多入口选择浮层。 */
  @Builder
  RouteSheet() {
    Column() {
      Column({ space: 14 }) {
        if (this.pendingAgent !== null) {
          Column({ space: 4 }) {
            Text(this.pendingAgent!.name).fontSize(17).fontWeight(FontWeight.Bold)
              .fontColor('#0F172A').width('100%')
            Text(this.pendingAgent!.role).fontSize(12.5).fontColor('#64748B').width('100%')
          }.width('100%')

          ForEach(this.pendingAgent!.routes, (route: AgentRoute) => {
            Button(route.label)
              .width('100%').height(46).fontSize(15).fontColor('#2563EB')
              .backgroundColor('#EFF6FF').borderRadius(12)
              .onClick(() => this.goRoute(route))
          }, (route: AgentRoute) => route.label)

          Button('取消')
            .width('100%').height(42).fontSize(14).fontColor('#64748B')
            .backgroundColor('#F1F5F9').borderRadius(12)
            .onClick(() => { this.showRouteSheet = false; })
        }
      }
      .width('86%').padding(20).backgroundColor('#FFFFFF').borderRadius(16)
    }
    .width('100%').height('100%')
    .backgroundColor('rgba(15, 23, 42, 0.45)')
    .justifyContent(FlexAlign.Center)
  }


  @Builder
  TabBar() {
    Row({ space: 4 }) {
      this.TabItem('◈', '对话', 0)
      this.TabItem('▦', '智能体', 1)
      this.TabItem('▤', '学习', 2)
      this.TabItem('◉', '我的', 3)
    }
    .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 10 })
    .backgroundColor('#FFFFFF').border({ width: { top: 1 }, color: '#EAECF0' })
  }

  /**
   * 单个标签项：只接收**静态**参数（图标、文案、下标），
   * 高亮状态一律在内部由 `this.activeTab` 推导，不通过参数传入。
   */
  @Builder
  TabItem(icon: string, label: string, index: number) {
    Column({ space: 3 }) {
      Text(icon).fontSize(19)
        .fontColor(this.activeTab === index ? '#2563EB' : '#667085')
      Text(label).fontSize(11)
        .fontWeight(this.activeTab === index ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.activeTab === index ? '#2563EB' : '#667085')
    }
    .layoutWeight(1).height(58).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .backgroundColor(this.activeTab === index ? '#EFF6FF' : '#FFFFFF').borderRadius(12)
    .onClick(() => { this.switchTab(index); })
  }

  /**
   * 标签切换。
   *
   * ★「对话」不是本页的一个标签，而是**另一个页面**（`pages/ChatMain`）。
   * 所以点它必须真的跳过去，不能只把 `activeTab` 置 0 —— 那样会停在本页
   * 一张"回到对话"的中间卡片上，用户还得再点一次才能说话。
   *
   * 用 `replaceUrl` 而不是 `pushUrl`：四个标签是**同级导航**，
   * 用 pushUrl 会让页面栈随每次切换不断增长（来回点几次就退不出去了）。
   * 这一点与 `ChatMain.switchTab` 保持同一套纪律。
   */
  private switchTab(index: number): void {
    if (index === 0) {
      // 对话页自己就是标签 0，直接回去，不产生任何中间页。
      router.replaceUrl({ url: 'pages/ChatMain' });
      return;
    }
    this.activeTab = index;
  }

  /**
   * 把后端的**内部标签**翻译成用户看得懂的话。
   *
   * ⚠️ 原来直接把 `contextTags` 原样 `join(' · ')` 显示出来，界面上就出现了
   * `已掌握 0 门课程、0 项临近作业 · exam_within_7d · r…` —— 那是给日志与联调看的
   * 英文枚举，不是给用户看的文案（实测反馈：「有的东西不要写给用户直接看」）。
   *
   * 翻不出来的标签**一律不显示**，宁可少说，也不把内部标识泄给用户。
   */
  private tagLabel(tag: string): string {
    if (tag === 'exam_within_7d' || tag === 'exam_within_7d_low_mastery') {
      return '考试临近';
    }
    if (tag === 'no_study_for_2d' || tag === 'recent_gap_2d') {
      return '两天没学习了';
    }
    if (tag === 'pending_ddl_within_2d') {
      return '有作业快截止';
    }
    if (tag === 'focus_session_active') {
      return '正在专注';
    }
    return '';
  }

  /** Agent 一句话感知摘要：先说"我知道什么"，再说"所以做什么"。 */
  private perceptionLine(): string {
    const courses: number = appState.courses.length;
    const ddls: number = appState.getUrgentDDLs().length;
    const d: ProactiveResponse | null = this.proactiveDecision;
    if (d !== null && d.contextTags.length > 0) {
      const labels: string[] = [];
      d.contextTags.forEach((tag: string) => {
        const label: string = this.tagLabel(tag);
        if (label.length > 0 && labels.indexOf(label) === -1) {
          labels.push(label);
        }
      });
      if (labels.length > 0) {
        return `已掌握 ${courses} 门课程、${ddls} 项临近作业 · ${labels.join(' · ')}`;
      }
    }
    return `已掌握 ${courses} 门课程、${ddls} 项临近作业`;
  }

  /**
   * ★ 唯一主行动 CTA。
   *
   * 三个候选来源按可靠性排序，**永远只渲染一个按钮**：
   *   1. 后端 proactive 决策（最权威，带 Agent 的 reason 与 factors）
   *   2. 后端当前计划的下一个未完成任务
   *   3. Fixture 今日最优任务
   * 全部不可用时给一个兜底动作（诊断练习），而不是让用户面对空白。
   */
  /** 是否已有明确的 Agent 建议可执行。 */
  private isActionReady(): boolean {
    if (this.proactiveDecision !== null && this.proactiveDecision!.action.type === 'focus') {
      return true;
    }
    if (this.currentAgentTask() !== null) {
      return true;
    }
    return this.isFixture() && this.primaryTask() !== null;
  }

  /** 主按钮分派：走的都是既有逻辑（写 focusTask 再跳专注设置页），只是收口到一处。 */
  private onPrimaryAction(): void {
    if (this.proactiveDecision !== null && this.proactiveDecision!.action.type === 'focus') {
      this.startProactiveTask();
      return;
    }
    const agentTask: PlanTask | null = this.currentAgentTask();
    if (agentTask !== null) {
      this.startAgentTask(agentTask);
      return;
    }
    // ⚠️ 必须先判 `isFixture()` 再求值 `primaryTask()`。
    // 原写法是 `const fixtureTask = this.primaryTask(); if (this.isFixture() && ...)` ——
    // 参数在 `&&` 之前就已求值，联机模式下 `primaryTask()` 照样被调用，
    // 于是那条"先做一组快速诊断"的兜底路径一点就崩（见 plan() 的注释）。
    const fixtureTask: LearningPlanTask | null = this.isFixture() ? this.primaryTask() : null;
    if (fixtureTask !== null) {
      this.startTask(fixtureTask);
      return;
    }
    this.openExercisePractice();
  }

  /** 窄入口：只在用户主动想"全面看看"时才铺开，不再默认铺开。 */
  private openApiEnvironment(): void {
    router.pushUrl({ url: 'pages/ApiEnvironment' });
  }

  private openAccount(): void {
    router.pushUrl({ url: 'pages/Account' });
  }

  /**
   * 回到登录 / 注册界面（切换身份）。
   *
   * **三种身份都要支持**，而不只是"已登录"：
   * * 已登录 → 先 `signOut()` 吊销服务端会话 + 清本地凭据 + 清缓存。
   *   否则 `EntryAbility` 下次启动会读本地凭据直接进主页，
   *   用户会觉得"我明明退出去了怎么又回来了"。
   * * 游客 / 离线 → 没有服务端凭据可吊销，直接跳；离线态还要切回联机数据源，
   *   否则登录成功后仍会走 Fixture 数据。
   *
   * 用 `replaceUrl` 而不是 `pushUrl`：登录页是身份入口，
   * 不该留在返回栈里，否则在登录页按返回又会回到「我的」。
   */
  private async goToLogin(): Promise<void> {
    if (this.isSwitchingIdentity) {
      return;
    }
    this.isSwitchingIdentity = true;
    if (AuthStore.isSignedIn()) {
      await AuthClient.signOut();
      appState.applyLogout();
    }
    // 离线态回到联机，否则登录后仍在读本地 Fixture 数据
    AgentApiClient.setUseFixture(false);
    this.isSwitchingIdentity = false;
    router.replaceUrl({ url: 'pages/Login' });
  }

  /** 诊断练习入口：也是 PrimaryActionCard 在无任何 Agent 建议时的兜底动作。 */
  private openExercisePractice(): void {
    router.pushUrl({ url: 'pages/ExercisePractice' });
  }

  private openAgentTrace(): void {
    router.pushUrl({ url: 'pages/AgentTrace' });
  }

  /** 身份标签：登录用户显示昵称，游客显示"体验身份"。 */
  private identityLabel(): string {
    if (appState.isSignedIn) {
      return appState.authNickname.length > 0 ? appState.authNickname : '我的';
    }
    return '体验身份';
  }

  private apiEnvironmentLabel(): string {
    const config: ApiClientConfig = AgentApiClient.getConfig();
    if (config.useFixture) return 'Fixture';
    return config.baseUrl === ApiDefaults.DEFAULT_BASE_URL ? '真 Agent 后端' : '自定义后端';
  }

  private agentStatusTitle(): string {
    const status: WorkflowStatusResponse | null = ClientCache.getWorkflowStatus();
    if (status !== null && status.currentAgent !== null) {
      return `${ApiDisplayFormatter.agent(status.currentAgent)} · ${ApiDisplayFormatter.workflowStatus(status.status)}`;
    }
    const workflow: WorkflowResponse | null = ClientCache.getWorkflow();
    return workflow === null ? '计划 Agent 已就绪' : `Agent 会话 · ${ApiDisplayFormatter.workflowStatus(workflow.status)}`;
  }

  private agentStatusDetail(): string {
    const status: WorkflowStatusResponse | null = ClientCache.getWorkflowStatus();
    if (status !== null && status.finalAction !== null) {
      return status.finalAction;
    }
    const workflow: WorkflowResponse | null = ClientCache.getWorkflow();
    if (workflow !== null) return `下一步：${ApiDisplayFormatter.nextAction(workflow.nextAction)}`;
    return this.isFixture() ? this.plan().decisionTrace.inputSummary : '等待真 Agent 后端返回会话状态。';
  }

  private returnToChat(): void {
    appState.leaveChatTask();
    ChatNavigation.returnToChat();
  }

  build() {
    Stack() {
      Column() {
        // ---------- 页头（对齐参考设计：小标 + 大标题 + 副标题） ----------
        Column({ space: 4 }) {
          Text('AI AGENTS')
            .fontSize(10).fontWeight(FontWeight.Bold).fontColor('#94A3B8')
            .letterSpacing(1.5).width('100%')
          Row() {
            Text(this.headerTitle()).fontSize(24).fontWeight(FontWeight.Bold).fontColor('#0F172A')
            Blank()
            Row({ space: 6 }) {
              Text('●').fontSize(9).fontColor(appState.isSignedIn ? '#10B981' : '#F59E0B')
              Text(this.identityLabel()).fontSize(11).fontWeight(FontWeight.Medium).fontColor('#2563EB')
            }
            .backgroundColor('#EFF6FF').borderRadius(10).padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => this.openAccount())
          }.width('100%').margin({ top: 2 })
          Text(this.headerSubtitle()).fontSize(13).fontColor('#64748B').width('100%')
        }
        .width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: 20, right: 20, top: 18, bottom: 14 }).backgroundColor('#FFFFFF')

        Scroll() {
          Column({ space: 16 }) {

            // ================= 标签 0：对话 =================
            // ★ 本页**没有**标签 0 的内容。
            //
            // 对话是独立页面 `pages/ChatMain`，点底部「对话」标签时
            // `switchTab(0)` 会直接 `replaceUrl` 跳过去 —— 不再渲染
            // "回到对话 / 打开对话"这类中间卡片，少一次点击。
            // 因此下面的分支从 1 开始。

            // ================= 标签 1：我的智能体（多智能体助学团） =================
            // 定位：**它替我做什么** —— 只放智能体能力，不放功能页快捷方式。
            if (this.activeTab === 1) {
              Row() {
                Text('选择合适能力，直接进入学习任务。').fontSize(12).fontColor('#94A3B8')
                Blank()
                Text(`${AGENT_SPECS.length} 个智能体`).fontSize(11).fontColor('#10B981')
                  .backgroundColor('#ECFDF5').borderRadius(8)
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              }.width('100%')

              Scroll() {
                Row({ space: 8 }) {
                  ForEach(AGENT_CATEGORIES, (category: string) => {
                    Text(category)
                      .fontSize(12)
                      .fontColor(this.agentFilter === category ? '#FFFFFF' : '#475467')
                      .backgroundColor(this.agentFilter === category ? '#2563EB' : '#FFFFFF')
                      .border({ width: 1, color: this.agentFilter === category ? '#2563EB' : '#E2E8F0' })
                      .borderRadius(16).padding({ left: 14, right: 14, top: 7, bottom: 7 })
                      .onClick(() => { this.agentFilter = category; })
                  }, (category: string) => category)
                }
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .width('100%')

              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
                ForEach(this.filteredAgents(), (item: AgentSpec) => {
                  this.AgentCard(item)
                }, (item: AgentSpec) => item.key)
              }.width('100%')

              Text('多智能体自治学习引擎：诊断 → 规划 → 练习 → 测评，由秘书智能体统筹编排。')
                .fontSize(11).fontColor('#94A3B8').lineHeight(17).width('100%')
            }

            // ================= 标签 2：学习（管理型操作，不做能力罗列） =================
            // 定位：**我要处理什么** —— 只放"管理"类操作。
            // 去重原则：智能体能力（建议/计划/错题/画像）一律不在此重复，
            // 需要它们时去「智能体」页点对应智能体；这里只解决"任务从哪来、时间怎么安排"。
            if (this.activeTab === 2) {
              this.PrimaryActionCard()
              this.PanelCard('上传作业与 DDL',
                '导入 CSV/JSON 课程表与作业截止时间。导入后，全部智能体的分析自动切换为你的真实数据。',
                '去上传 / 导入数据', 'pages/CourseImport')

              Row() {
                Text('任务安排').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A')
                Blank()
                Text(`${appState.getUrgentDDLs().length} 项临近`).fontSize(11)
                  .fontColor(appState.getUrgentDDLs().length > 0 ? '#B45309' : '#10B981')
              }.width('100%').margin({ top: 4 })

              this.PanelRow('◱', '开始专注', '按任务倒计时，结束后自动生成复盘', 'pages/FocusSetup')
              this.PanelRow('▣', '课程与作业清单', '查看已导入的课程与 DDL', 'pages/CourseImport')

              // 知识库入口：让 Agent 的判断有据可依（引用你自己的课程资料）
              this.PanelCard('我的知识库',
                '上传课程讲义、题库或笔记（TXT / Markdown / CSV / JSON）。' +
                'Agent 会从中提取知识点与易错点，回答时标注资料来源与章节。',
                '进入我的知识库', 'pages/KnowledgeBase')
            }

            // ================= 标签 3：我的（身份 / 数据 / 搭子） =================
            if (this.activeTab === 3) {
              Column({ space: 10 }) {
                Row({ space: 10 }) {
                  Text(appState.isSignedIn ? '👤' : '👥').fontSize(22)
                  Column({ space: 3 }) {
                    Text(appState.authNickname).fontSize(17).fontWeight(FontWeight.Bold)
                      .fontColor('#0F172A').width('100%')
                    Text(appState.isSignedIn ? '独立账号 · 数据归你所有' : '体验身份（演示数据）')
                      .fontSize(11.5).fontColor(appState.isSignedIn ? '#1E6B3A' : '#B45309')
                      .width('100%')
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Text('管理 ›').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#2563EB')
                }.width('100%')
                Button('账号与密码管理')
                  .width('100%').height(44).fontSize(14).fontColor('#2563EB')
                  .backgroundColor('#EFF6FF').borderRadius(12)
                  .onClick(() => this.openAccount())

                // 切换到登录 / 注册界面。
                //
                // **三种身份都必须能走这条路**，而不只是"已登录"：
                //   · 已登录 → 先吊销服务端会话再跳，否则下次启动又直接进主页
                //   · 游客   → 直接跳（没有服务端凭据可吊销）
                //   · 离线   → 先切回联机数据源，再跳
                // 否则用户一旦以游客身份进入，就再也没法换账号了。
                Button('切换账号 / 退出登录')
                  .width('100%').height(44).fontSize(14).fontColor('#B45309')
                  .backgroundColor('#FFFBEB').borderRadius(12)
                  .border({ width: 1, color: '#FDE68A' })
                  .onClick(() => { this.goToLogin(); })
                Text(appState.isSignedIn
                  ? '退出后将回到登录 / 注册界面，可以换一个账号进来。账号数据仍保留在服务端。'
                  : '当前是体验身份。点击可回到登录 / 注册界面，用你自己的账号进入。')
                  .fontSize(11).fontColor('#98A2B3').lineHeight(17).width('100%')
              }
              .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
              .border({ width: 1, color: '#EAECF0' })

              Row() {
                Text('学习数据').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A')
                Blank()
                Text('明细 ›').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#2563EB')
                  .onClick(() => router.pushUrl({ url: 'pages/LearningHistory' }))
              }.width('100%').margin({ top: 4 })

              Row({ space: 10 }) {
                this.StatCard(`${appState.getPlanProgress()}%`, '任务完成度')
                this.StatCard(`${appState.getFocusSummary().todayMinutes}`, '今日专注分钟')
                this.StatCard(`${appState.getFocusSummary().recentSessions.length}`, '专注记录次数')
              }.width('100%')

              Row({ space: 10 }) {
                this.StatCard(`${appState.getFocusSummary().streakDays}`, '连续学习天数')
                this.StatCard(`${Math.round(appState.getFocusSummary().completionRate)}%`, '专注完成率')
                this.StatCard(`${appState.getUrgentDDLs().length}`, '待处理作业')
              }.width('100%')

              this.PanelRow('◰', '学习复盘', '汇总任务、知识点与下一步建议', 'pages/ReviewSummary')

              Row() {
                Text('我的学习搭子').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A')
              }.width('100%').margin({ top: 4 })

              this.PanelRow('◑', '搭子与协同', '查看匹配结果与协同学习计划', 'pages/PartnerMatch')

              Row() {
                Text('开发调试：数据源设置').fontSize(12).fontColor('#98A2B3')
                Blank()
                Text('配置 →').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#98A2B3')
              }.width('100%').padding(12).backgroundColor('#FFFFFF').borderRadius(12)
              .border({ width: 1, color: '#EAECF0' }).onClick(() => this.openApiEnvironment())
            }

            Blank().height(12)
          }.width('100%').padding(20)
        }.layoutWeight(1)

        this.TabBar()
      }
      .width('100%').height('100%').backgroundColor('#F7F8FA')
      AIFloatButton()
      // 多入口智能体的选择浮层（覆盖在最上层）
      if (this.showRouteSheet) {
        this.RouteSheet()
      }
    }.width('100%').height('100%')
  }


}


/** 智能体能力的静态描述（常量，不含状态）。 */
interface AgentSpec {
  key: string;
  icon: string;
  name: string;
  category: string;
  /** 一句话职能（比 desc 更短，用于卡片上的粗体副标题）。 */
  role: string;
  desc: string;
  /** 该智能体可直达的页面（一个智能体可对应多个既有页面，不新增 Agent 行为）。 */
  routes: AgentRoute[];
  ready: boolean;
}

/** 智能体下的一个可直达入口。 */
interface AgentRoute {
  label: string;
  target: string;
  prompt: string;
}

/**
 * 本项目的 Agent 能力清单 —— 与后端 6 类意图 + 各功能页一一对应。
 *
 * 这张表就是「我的智能体」页的唯一数据源；增删能力只改这里。
 * `prompt` 非空表示该能力走对话链路（预填问题后进对话页）；
 * `target` 是直达页面；`target === 'pages/Index'` 表示回到首页主行动卡。
 */
/**
 * 本项目的多智能体助学团 —— 对齐指导老师建议的四智能体架构：
 *
 *   诊断智能体（学情诊断） → 规划智能体（路径规划）
 *                          → 练习智能体（推送练习）
 *                          → 测评智能体（效果评估）
 *   秘书智能体（总控编排）统筹上面四个，决定"下一步叫谁"。
 *
 * ⚠️ **后端逻辑完全未改动**：这 5 张卡只是把既有页面/意图**归并展示**，
 * 每个 `routes` 仍指向原有页面，不新增也不删除任何 Agent 行为。
 *
 * 为什么从 12 张收到 5 张：原先把「学习记录 / 课程导入 / 专注模式 / 学习复盘」
 * 这类**功能页**也当成了智能体，导致"智能体"这个概念被稀释。
 * 按老师给的架构，智能体应当对应**认知职能**，功能页归到「学习」标签。
 */
const AGENT_SPECS: AgentSpec[] = [
  {
    key: 'diagnosis', icon: '◐', name: '诊断智能体', category: '学情诊断',
    role: '找出你哪里薄弱',
    desc: '读取错题与练习记录，定位知识点短板与错误类型，形成可复核的学情证据。',
    routes: [
      { label: '错题诊断', target: 'pages/WrongQuestion', prompt: '' },
      { label: '学情画像', target: 'pages/StudyTags', prompt: '' }
    ],
    ready: true
  },
  {
    key: 'planner', icon: '◈', name: '规划智能体', category: '路径规划',
    role: '决定今天先学什么',
    desc: '按五因子（掌握度/错误强度/重要性/紧迫度/先修影响）算出最优任务，并随掌握度变化自动重规划。',
    routes: [
      { label: '今日学习建议', target: 'pages/StudySuggestion', prompt: '' },
      { label: 'Agent 学习计划', target: 'pages/StudyPlan', prompt: '' }
    ],
    ready: true
  },
  {
    key: 'exercise', icon: '◱', name: '练习智能体', category: '推送练习',
    role: '按薄弱点推题',
    desc: '按知识点抽取题目并计时专注，提交后由确定性代码判分，掌握度随之更新。',
    routes: [
      { label: '专项练习', target: 'pages/ExercisePractice', prompt: '' }
    ],
    ready: true
  },
  {
    key: 'assessment', icon: '◰', name: '测评智能体', category: '效果评估',
    role: '验证学习是否有效',
    desc: '汇总掌握度变化、计划重排与学习证据，输出复盘与下一步建议，形成全过程可信记录。',
    routes: [
      { label: '学习复盘', target: 'pages/ReviewSummary', prompt: '' }
    ],
    ready: true
  },
  {
    key: 'secretary', icon: '◇', name: '秘书智能体', category: '总控编排',
    role: '统筹上面四个',
    desc: '判断「下一步该叫哪个智能体」，并在对的时刻主动提醒你。全程留痕、可复核，不含模型思维链。',
    routes: [
      { label: 'Agent 决策过程', target: 'pages/AgentTrace', prompt: '' }
    ],
    ready: true
  }
];

/** 首页横滑区的常用智能体（全部 5 个）。 */
const QUICK_AGENTS: AgentSpec[] = AGENT_SPECS;

/** 能力分类筛选项。 */
const AGENT_CATEGORIES: string[] = ['全部', '学情诊断', '路径规划', '推送练习', '效果评估', '总控编排'];
