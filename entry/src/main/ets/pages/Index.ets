import router from '@ohos.router';
import { appState } from '../data/AppState';
import { FocusTask, LearningPlanTask, WeeklyLearningPlan } from '../models/AgentModels';
import { LocalAgentService } from '../services/LocalAgentService';
import { DateHelper } from '../utils/DateHelper';
import { ChatNavigation } from '../services/ChatNavigation';
import { AIFloatButton } from '../components/AIFloatButton';
import { FactorBreakdownCard } from '../components/FactorBreakdownCard';
import { AgentApiClient, ApiClientConfig } from '../api/AgentApiClient';
import { LearningPlan, PlanTask, ProactiveResponse, WorkflowResponse, WorkflowStatusResponse } from '../api/ApiModels';
import { ClientCache } from '../cache/ClientCache';
import { WorkflowViewModel } from '../viewmodels/WorkflowViewModel';
import { ApiDisplayFormatter } from '../utils/ApiDisplayFormatter';
import { PlanViewModel } from '../viewmodels/PlanViewModel';
import { ProactiveViewModel } from '../viewmodels/ProactiveViewModel';

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
  private workflowViewModel: WorkflowViewModel = new WorkflowViewModel();
  private planViewModel: PlanViewModel = new PlanViewModel();
  private proactiveViewModel: ProactiveViewModel = new ProactiveViewModel();
  private workflowRequestVersion: number = 0;
  private planRequestVersion: number = 0;
  private proactiveRequestVersion: number = 0;
  private isPageActive: boolean = false;

  aboutToAppear(): void {
    this.isPageActive = true;
    this.ensurePlan();
    this.refreshKey++;
    this.bootstrapWorkflow();
    this.loadProactiveDecision();
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.workflowRequestVersion++;
    this.planRequestVersion++;
    this.proactiveRequestVersion++;
    this.isWorkflowRefreshing = false;
  }

  private async loadProactiveDecision(): Promise<void> {
    this.isProactiveLoading = true;
    this.proactiveMessage = '';
    const requestVersion: number = ++this.proactiveRequestVersion;
    const daysLeft: number = appState.getHighPriorityCourse().exam.daysLeft;
    const state = await this.proactiveViewModel.load(appState.currentUser.userId, daysLeft, false);
    if (!this.isPageActive || requestVersion !== this.proactiveRequestVersion) return;
    this.proactiveDecision = state.decision;
    this.proactiveMessage = state.errorMessage;
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
      created = workflow !== null;
    }
    if (workflow !== null) {
      if (created) {
        await this.workflowViewModel.runUntilComplete(1);
      } else {
        await this.workflowViewModel.refreshStatus(true);
      }
    }
    if (!this.isFixture()) {
      await this.loadAgentPlan(true);
    }
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

  private plan(): WeeklyLearningPlan {
    this.ensurePlan();
    return appState.weeklyPlan!;
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

  private openPlan(): void {
    router.pushUrl({ url: 'pages/StudyPlan' });
  }

  private openLearning(): void {
    router.pushUrl({ url: 'pages/CourseImport' });
  }

  private openProfile(): void {
    router.pushUrl({ url: 'pages/LearningHistory' });
  }

  private openApiEnvironment(): void {
    router.pushUrl({ url: 'pages/ApiEnvironment' });
  }

  private openExercisePractice(): void {
    router.pushUrl({ url: 'pages/ExercisePractice' });
  }

  private openAgentTrace(): void {
    router.pushUrl({ url: 'pages/AgentTrace' });
  }

  private apiEnvironmentLabel(): string {
    const config: ApiClientConfig = AgentApiClient.getConfig();
    if (config.useFixture) return 'Fixture';
    return config.baseUrl === 'http://10.0.2.2:5000' ? '真 Agent 后端' : '自定义后端';
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
    if (workflow !== null) return `下一步：${workflow.nextAction}`;
    return this.isFixture() ? this.plan().decisionTrace.inputSummary : '等待真 Agent 后端返回会话状态。';
  }

  private returnToChat(): void {
    appState.leaveChatTask();
    ChatNavigation.returnToChat();
  }

  @Builder
  BottomNavItem(icon: string, label: string, active: boolean, action: () => void) {
    Column({ space: 3 }) {
      Text(icon).fontSize(19)
      Text(label).fontSize(11).fontWeight(active ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(active ? '#2563EB' : '#667085')
    }
    .layoutWeight(1).height(58).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .backgroundColor(active ? '#EFF6FF' : '#FFFFFF').borderRadius(12).onClick(action)
  }

  @Builder
  AgentStatus() {
    Row({ space: 10 }) {
      Column() {
        Text('AI').fontSize(12).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
      }.width(30).height(30).borderRadius(15).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center).backgroundColor('#2563EB')
      Column({ space: 2 }) {
        Text(this.agentStatusTitle()).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#1F2937')
        Text(this.agentStatusDetail()).fontSize(11).fontColor('#667085').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text(this.apiEnvironmentLabel()).fontSize(11).fontWeight(FontWeight.Bold).fontColor('#2563EB')
        .backgroundColor('#FFFFFF').borderRadius(9).padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .onClick(() => this.openApiEnvironment())
    }
    .width('100%').padding(14).backgroundColor('#EFF6FF').borderRadius(16)
  }

  @Builder
  ProactiveDecisionCard(decision: ProactiveResponse) {
    Column({ space: 10 }) {
      Row() {
        Text(decision.shouldNotify ? 'Agent 主动提醒' : 'Agent 情境建议')
          .fontSize(13).fontWeight(FontWeight.Bold).fontColor('#B45309')
        Blank()
        Text(decision.channel === 'reminder' ? '建议现在处理' : '已静默评估')
          .fontSize(11).fontColor('#92400E').backgroundColor('#FEF3C7').borderRadius(9)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      }.width('100%')
      if (decision.title.length > 0) {
        Text(decision.title).fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
      }
      Text(decision.body).fontSize(13).fontColor('#475467').lineHeight(20).width('100%')
      if (decision.cardData.taskName !== undefined) {
        Text(`${decision.cardData.taskName} · ${decision.cardData.durationMinutes ?? 45} 分钟`)
          .fontSize(13).fontWeight(FontWeight.Medium).fontColor('#2563EB').width('100%')
      }
      if (decision.action.type === 'focus') {
        Button('按 Agent 建议开始专注').width('100%').height(42).fontSize(13).fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF').backgroundColor('#D97706').borderRadius(11)
          .onClick(() => this.startProactiveTask())
      }
    }.width('100%').padding(16).backgroundColor('#FFFBEB').borderRadius(16)
      .border({ width: 1, color: '#FDE68A' })
  }

  @Builder
  AgentPlanCard(task: PlanTask) {
    Column({ space: 12 }) {
      Row() {
        Text('Agent 当前计划').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#2563EB')
        Blank()
        Text(`Plan V${this.agentPlan?.version ?? 0}`)
          .fontSize(11).fontColor('#0F766E').backgroundColor('#ECFDF5').borderRadius(9)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      }.width('100%')
      Text(task.knowledgePointName).fontSize(22).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
      Text(`${task.durationMinutes} 分钟 · ${task.status}`)
        .fontSize(13).fontColor('#667085').width('100%')
      Text(this.agentPlan?.reason ?? '任务来自后端当前学习计划。').fontSize(13).fontColor('#475467').lineHeight(20).width('100%')
      Button('开始专注').width('100%').height(44).fontSize(14).fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(12).onClick(() => this.startAgentTask(task))
    }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
      .border({ width: 1, color: '#BFDBFE' })
  }

  @Builder
  PrimaryTaskCard(task: LearningPlanTask) {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 4 }) {
          Text('今日最优任务').fontSize(12).fontWeight(FontWeight.Bold).fontColor('#2563EB')
          Text(task.title).fontSize(22).fontWeight(FontWeight.Bold).fontColor('#1F2937').maxLines(2)
          Text(`${task.course} · ${task.knowledgePoint} · ${task.plannedMinutes} 分钟`).fontSize(13).fontColor('#667085')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(task.priorityLabel).fontSize(11).fontWeight(FontWeight.Medium).fontColor('#B42318')
          .backgroundColor('#FEF3F2').borderRadius(10).padding({ left: 8, right: 8, top: 4, bottom: 4 })
      }.width('100%')
      Text(task.reason).fontSize(13).fontColor('#475467').lineHeight(20)
      Column({ space: 4 }) {
        Text('完成标准').fontSize(11).fontWeight(FontWeight.Bold).fontColor('#667085')
        Text(task.completionCriteria).fontSize(13).fontColor('#1F2937').lineHeight(19)
      }.width('100%').padding(12).backgroundColor('#F7F8FA').borderRadius(12)
      Button('开始这项任务')
        .width('100%').height(48).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        .backgroundColor('#2563EB').borderRadius(14).onClick(() => this.startTask(task))
    }
    .width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(20).border({ width: 1, color: '#EEF2FF' })
  }

  @Builder
  TaskRow(task: LearningPlanTask, index: number) {
    Row({ space: 12 }) {
      Text((index + 1).toString()).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#2563EB')
        .width(28).height(28).textAlign(TextAlign.Center).borderRadius(14).backgroundColor('#EFF6FF')
      Column({ space: 3 }) {
        Text(task.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor('#1F2937').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${task.course} · ${task.plannedMinutes} 分钟 · ${task.type === 'assignment' ? '作业' : '学习任务'}`).fontSize(12).fontColor('#667085')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('开始').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#2563EB').onClick(() => this.startTask(task))
    }
    .width('100%').padding({ top: 12, bottom: 12 })
  }

  build() {
    Stack() {
    Column() {
      Row() {
        Column({ space: 3 }) {
          Text('全部工具').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#1F2937')
          Text(appState.getChatTaskContext()).fontSize(11).fontColor('#667085')
        }.alignItems(HorizontalAlign.Start)
        Blank()
        Text('返回对话').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#2563EB')
          .backgroundColor('#EFF6FF').borderRadius(12).padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .onClick(() => this.returnToChat())
      }.width('100%').padding({ left: 20, right: 20, top: 18, bottom: 12 }).backgroundColor('#FFFFFF')

      Scroll() {
        Column({ space: 16 }) {
          this.AgentStatus()
          if (this.proactiveDecision !== null) {
            this.ProactiveDecisionCard(this.proactiveDecision!)
            if (this.proactiveDecision!.factors.length > 0) {
              FactorBreakdownCard({ factors: this.proactiveDecision!.factors, reason: this.proactiveDecision!.reason })
            }
          } else if (this.isProactiveLoading) {
            Row({ space: 10 }) {
              LoadingProgress().width(22).height(22).color('#D97706')
              Text('Agent 正在评估是否需要主动提醒…').fontSize(12).fontColor('#667085')
            }.width('100%').padding(14).backgroundColor('#FFFBEB').borderRadius(14)
          } else if (this.proactiveMessage.length > 0) {
            Text(`主动建议暂不可用：${this.proactiveMessage}`).fontSize(12).fontColor('#92400E')
              .width('100%').padding(12).backgroundColor('#FFFBEB').borderRadius(12)
              .onClick(() => this.loadProactiveDecision())
          }
          Row() {
            Column({ space: 2 }) {
              Text('开发调试：数据源设置').fontSize(13).fontColor('#475467')
              Text('仅供前端测试和接口联调使用').fontSize(10).fontColor('#98A2B3')
            }.alignItems(HorizontalAlign.Start)
            Blank()
            Text('配置 →').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#2563EB')
          }.width('100%').padding(13).backgroundColor('#FFFFFF').borderRadius(12)
          .border({ width: 1, color: '#E2E8F0' }).onClick(() => this.openApiEnvironment())
          Text('今天，先完成最重要的一件事').fontSize(24).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
          if (this.isFixture() && this.primaryTask() !== null) {
            this.PrimaryTaskCard(this.primaryTask()!)
          } else if (this.isFixture()) {
            Column({ space: 8 }) {
              Text('今日任务已完成').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1F2937')
              Text('Agent 已把后续任务安排到明天，去看看本周进度吧。').fontSize(13).fontColor('#667085')
              Button('查看本周计划').width('100%').height(44).fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(12).onClick(() => this.openPlan())
            }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
          } else if (this.currentAgentTask() !== null) {
            this.AgentPlanCard(this.currentAgentTask()!)
          } else if (this.isAgentPlanLoading) {
            Row({ space: 10 }) {
              LoadingProgress().width(24).height(24).color('#2563EB')
              Text('正在读取 Agent 当前计划…').fontSize(13).fontColor('#667085')
            }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(14)
          } else {
            Column({ space: 8 }) {
              Text('当前计划暂不可用').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#B45309')
              Text(this.agentPlanMessage.length > 0 ? this.agentPlanMessage : '后端当前计划中没有待执行任务。')
                .fontSize(12).fontColor('#667085').lineHeight(18)
              Text('重试').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#2563EB').onClick(() => this.loadAgentPlan(true))
            }.width('100%').padding(16).backgroundColor('#FFFBEB').borderRadius(14)
          }

          if (this.isFixture()) {
            Column({ space: 4 }) {
            Row() {
              Text('今日计划').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1F2937')
              Blank()
              Text(`${this.todayTasks().length} 项待执行`).fontSize(12).fontColor('#667085')
            }.width('100%').margin({ bottom: 4 })
            ForEach(this.todayTasks().slice(0, 3), (task: LearningPlanTask, index: number) => {
              this.TaskRow(task, index)
              if (index < this.todayTasks().slice(0, 3).length - 1) {
                Divider().color('#EAECF0')
              }
            }, (task: LearningPlanTask) => task.id)
            Text('查看全部计划 →').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#2563EB').width('100%').textAlign(TextAlign.Center)
              .margin({ top: 8 }).onClick(() => this.openPlan())
            }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18).border({ width: 1, color: '#EAECF0' })
          } else {
            Button('查看全部计划 →').width('100%').height(46).fontSize(14).fontWeight(FontWeight.Bold)
              .fontColor('#2563EB').backgroundColor('#FFFFFF').border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
              .onClick(() => this.openPlan())
          }

          Row({ space: 10 }) {
            this.Metric(`${appState.getFocusSummary().todayMinutes}`, '今日专注分钟')
            this.Metric(`${appState.getPlanProgress()}%`, '本周完成度')
            this.Metric(`${appState.getUrgentDDLs().length}`, '待处理作业')
          }.width('100%')

          Row({ space: 10 }) {
            Button('课程与作业').layoutWeight(1).height(44).fontSize(13).fontColor('#2563EB').backgroundColor('#FFFFFF')
              .border({ width: 1, color: '#BFDBFE' }).borderRadius(12).onClick(() => router.pushUrl({ url: 'pages/CourseImport' }))
            Button('错题复习').layoutWeight(1).height(44).fontSize(13).fontColor('#2563EB').backgroundColor('#FFFFFF')
              .border({ width: 1, color: '#BFDBFE' }).borderRadius(12).onClick(() => router.pushUrl({ url: 'pages/WrongQuestion' }))
          }.width('100%').margin({ bottom: 24 })

          Row({ space: 10 }) {
            Button('开始诊断练习').layoutWeight(1).height(46).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
              .backgroundColor('#2563EB').borderRadius(12).onClick(() => this.openExercisePractice())
            Button('查看 Agent 决策过程').layoutWeight(1).height(46).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#2563EB')
              .backgroundColor('#FFFFFF').border({ width: 1, color: '#BFDBFE' }).borderRadius(12).onClick(() => this.openAgentTrace())
          }.width('100%').margin({ bottom: 24 })
        }.width('100%').padding(20)
      }.layoutWeight(1)

      Row({ space: 4 }) {
        this.BottomNavItem('⌂', '首页', true, () => {})
        this.BottomNavItem('◷', '计划', false, () => this.openPlan())
        this.BottomNavItem('▣', '学习', false, () => this.openLearning())
        this.BottomNavItem('◉', '我的', false, () => this.openProfile())
      }
      .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 10 })
      .backgroundColor('#FFFFFF').border({ width: { top: 1 }, color: '#EAECF0' })
    }.width('100%').height('100%').backgroundColor('#F7F8FA')
    AIFloatButton()
  }.width('100%').height('100%')
  }

  @Builder
  Metric(value: string, label: string) {
    Column({ space: 4 }) {
      Text(value).fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1F2937')
      Text(label).fontSize(11).fontColor('#667085').textAlign(TextAlign.Center)
    }.layoutWeight(1).alignItems(HorizontalAlign.Center).padding({ top: 13, bottom: 13 }).backgroundColor('#FFFFFF').borderRadius(14)
  }
}
