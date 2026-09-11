import router from '@ohos.router';
import { appState } from '../data/AppState';
import { FocusTask, LearningPlanTask, WeeklyLearningPlan } from '../models/AgentModels';
import { LocalAgentService } from '../services/LocalAgentService';
import { DateHelper, WeekDay } from '../utils/DateHelper';
import { ChatNavigation } from '../services/ChatNavigation';
import { AIFloatButton } from '../components/AIFloatButton';
import { LearningPlan, PlanTask } from '../api/ApiModels';
import { PlanViewModel } from '../viewmodels/PlanViewModel';

@Entry
@Component
struct StudyPlan {
  @State activeDay: string = DateHelper.getTodayLabel();
  @State refreshKey: number = 0;
  @State isApiPlanLoading: boolean = true;
  @State apiPlan: LearningPlan | null = null;
  @State apiPlanMessage: string = '';
  private weekDays: WeekDay[] = DateHelper.getWeekDays();
  private planViewModel: PlanViewModel = new PlanViewModel();
  private planRequestVersion: number = 0;
  private isPageActive: boolean = false;

  aboutToAppear(): void {
    this.isPageActive = true;
    // 更新周日期（每次进入页面重新计算）
    this.weekDays = DateHelper.getWeekDays();
    const todayLabel: string = DateHelper.getTodayLabel();
    // 匹配当前活跃日期到真实日期
    let matched: boolean = false;
    for (let i: number = 0; i < this.weekDays.length; i++) {
      if (this.weekDays[i].fullLabel === this.activeDay ||
          this.weekDays[i].monthDay === this.activeDay) {
        this.activeDay = this.weekDays[i].fullLabel;
        matched = true;
        break;
      }
    }
    if (!matched) {
      this.activeDay = todayLabel;
      // 找到对应的 fullLabel
      for (let i: number = 0; i < this.weekDays.length; i++) {
        if (this.weekDays[i].monthDay === todayLabel) {
          this.activeDay = this.weekDays[i].fullLabel;
          break;
        }
      }
    }

    if (appState.weeklyPlan === null) {
      appState.setWeeklyPlan(LocalAgentService.generateWeeklyPlan(appState.courses, appState.homeworkDDLs, appState.currentUser));
    }

    this.refreshKey++;
    this.loadCurrentPlan();
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.planRequestVersion++;
  }

  private async loadCurrentPlan(forceRefresh: boolean = false): Promise<void> {
    if (this.isApiPlanLoading && forceRefresh) {
      return;
    }
    const requestVersion: number = ++this.planRequestVersion;
    this.isApiPlanLoading = true;
    const state = await this.planViewModel.load(forceRefresh);
    if (!this.isPageActive || requestVersion !== this.planRequestVersion) {
      return;
    }
    this.apiPlan = state.plan;
    this.apiPlanMessage = state.errorMessage;
    this.isApiPlanLoading = false;
  }

  private plan(): WeeklyLearningPlan {
    return appState.weeklyPlan!;
  }

  private currentTasks(): LearningPlanTask[] {
    return this.plan().tasks.filter((task: LearningPlanTask) => {
      // 匹配任务日期标签与当前选中的日期
      // activeDay 格式: "7月19日 周日"，提取日期部分做模糊匹配
      const spaceIndex: number = this.activeDay.indexOf(' ');
      const datePart: string = spaceIndex > 0 ? this.activeDay.substring(0, spaceIndex) : this.activeDay;
      return task.dateLabel.indexOf(datePart) !== -1 ||
             task.dateLabel === this.activeDay;
    });
  }

  private startTask(task: LearningPlanTask): void {
    appState.updatePlanTaskStatus(task.id, 'in_progress');
    appState.setFocusTask({
      course: task.course, task: task.title, plannedMinutes: task.plannedMinutes,
      source: task.canCollaborate ? 'collaborative' : 'agent', mode: 'normal', timerType: 'countdown', planTaskId: task.id
    } as FocusTask);
    router.pushUrl({ url: 'pages/FocusSetup' });
  }

  private deferTask(task: LearningPlanTask): void {
    appState.updatePlanTaskStatus(task.id, 'deferred');
    this.plan().adjustmentMessage = `已将"${task.title}"延后，Agent 会在明天重新评估优先级。`;
    this.refreshKey++;
  }

  private goBack(): void {
    appState.leaveChatTask();
    router.back();
  }

  private completePlan(): void {
    appState.completeChatTask(
      '本周复习计划已确认。',
      '从今天的第一项任务开始，完成后我会继续为你调整安排。',
      '查看今天任务',
      'pages/StudyPlan'
    );
    router.back();
  }

  private taskStatusLabel(status: string): string {
    if (status === 'completed') return '已完成';
    if (status === 'partial') return '部分完成';
    if (status === 'deferred') return '已延后';
    if (status === 'in_progress') return '进行中';
    return '待执行';
  }

  /** 判断当前选中的day是否是今天 */
  private isActiveDayToday(): boolean {
    const todayLabel: string = DateHelper.getTodayLabel();
    return this.activeDay.indexOf(todayLabel) !== -1;
  }

  @Builder
  ApiPlanCard() {
    Column({ space: 10 }) {
      Row() {
        Text('当前学习计划').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1F2937')
        Blank()
        if (this.apiPlan !== null) {
          Text(`V${this.apiPlan.version}`).fontSize(11).fontWeight(FontWeight.Bold).fontColor('#2563EB')
            .backgroundColor('#EFF6FF').borderRadius(8).padding({ left: 7, right: 7, top: 3, bottom: 3 })
        }
      }.width('100%')

      if (this.isApiPlanLoading) {
        Row({ space: 8 }) {
          LoadingProgress().width(18).height(18).color('#2563EB')
          Text('正在读取当前计划…').fontSize(13).fontColor('#667085')
        }.width('100%')
      } else if (this.apiPlan !== null) {
        if (this.apiPlan.reason !== undefined) {
          Text(this.apiPlan.reason).fontSize(13).fontColor('#475467').lineHeight(19).width('100%')
        }
        Text(`基于画像版本 ${this.apiPlan.generatedFromProfileVersion} 生成`)
          .fontSize(12).fontColor('#667085').width('100%')
        ForEach(this.apiPlan.tasks, (task: PlanTask) => {
          Row({ space: 8 }) {
            Text(task.priority === 'high' ? '优先' : '计划')
              .fontSize(10).fontColor('#2563EB').backgroundColor('#EFF6FF').borderRadius(7).padding({ left: 6, right: 6, top: 3, bottom: 3 })
            Text(`${task.knowledgePointName} · ${task.durationMinutes} 分钟`)
              .fontSize(13).fontColor('#1F2937').layoutWeight(1)
            Text(task.status).fontSize(11).fontColor('#667085')
          }.width('100%').padding(10).backgroundColor('#F8FAFC').borderRadius(10)
        }, (task: PlanTask) => task.taskId)
      } else {
        Text(this.apiPlanMessage).fontSize(13).fontColor('#B45309').lineHeight(19).width('100%')
      }

      Button('刷新当前计划')
        .width('100%').height(38).fontSize(13).fontColor('#2563EB').backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#BFDBFE' }).borderRadius(10).enabled(!this.isApiPlanLoading)
        .onClick(() => this.loadCurrentPlan(true))
    }.width('100%').padding(15).backgroundColor('#FFFFFF').border({ width: 1, color: '#BFDBFE' }).borderRadius(16)
  }

  @Builder
  DayTab(day: WeekDay) {
    Column({ space: 2 }) {
      Text(day.dayOfWeek)
        .fontSize(11)
        .fontWeight(this.activeDay === day.fullLabel ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.activeDay === day.fullLabel ? '#FFFFFF' : '#667085')
      Text(day.monthDay)
        .fontSize(10)
        .fontWeight(this.activeDay === day.fullLabel ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.activeDay === day.fullLabel ? '#FFFFFF' : '#98A2B3')
    }
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor(this.activeDay === day.fullLabel ? '#2563EB' : '#FFFFFF')
    .borderRadius(12)
    .border({ width: 1, color: this.activeDay === day.fullLabel ? '#2563EB' : '#EAECF0' })
    .onClick(() => {
      this.activeDay = day.fullLabel;
      this.refreshKey++;
    })
  }

  @Builder
  TaskCard(task: LearningPlanTask) {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 4 }) {
          Text(task.title).fontSize(17).fontWeight(FontWeight.Bold).fontColor('#1F2937').maxLines(2)
          Text(`${task.course} · ${task.knowledgePoint} · ${task.plannedMinutes} 分钟`).fontSize(12).fontColor('#667085')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text(this.taskStatusLabel(task.status)).fontSize(11).fontWeight(FontWeight.Medium)
          .fontColor(task.status === 'completed' ? '#2563EB' : '#2563EB').backgroundColor(task.status === 'completed' ? '#EFF6FF' : '#EFF6FF')
          .borderRadius(10).padding({ left: 8, right: 8, top: 4, bottom: 4 })
      }.width('100%')
      Text(task.reason).fontSize(13).fontColor('#475467').lineHeight(19)
      Column({ space: 5 }) {
        Text('完成标准').fontSize(11).fontWeight(FontWeight.Bold).fontColor('#667085')
        Text(task.completionCriteria).fontSize(13).fontColor('#1F2937').lineHeight(19)
      }.width('100%').padding(12).backgroundColor('#F7F8FA').borderRadius(12)
      Row({ space: 10 }) {
        if (task.status !== 'completed') {
          Button('开始任务').layoutWeight(1).height(42).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            .backgroundColor('#2563EB').borderRadius(12).onClick(() => this.startTask(task))
          Button('延后').layoutWeight(1).height(42).fontSize(13).fontColor('#2563EB').backgroundColor('#FFFFFF')
            .border({ width: 1, color: '#BFDBFE' }).borderRadius(12).onClick(() => this.deferTask(task))
        }
      }.width('100%')
      if (task.canCollaborate) {
        Text('可选择学习搭子共同完成 →').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#3976D3')
          .onClick(() => router.pushUrl({ url: 'pages/PartnerMatch' }))
      }
    }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18).border({ width: 1, color: '#EAECF0' })
  }

  build() {
    Stack() {
    Column() {
      // 顶部导航
      Row() {
        Text('← 返回').fontSize(14).fontColor('#64748B').fontWeight(FontWeight.Medium)
          .onClick(() => this.goBack())
        Blank()
        Text('本周计划').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB')
      }.width('100%').padding({ left: 20, right: 20, top: 18, bottom: 14 }).backgroundColor('#FFFFFF')

      Scroll() {
        Column({ space: 16 }) {
          // ===== 标题区 =====
          Text('我的学习计划')
            .fontSize(25).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')

          // ===== 描述文本 =====
          Text('你的每一次进步，都会让接下来的学习路径更加精准——放心跟着走就好。')
            .fontSize(13).fontColor('#667085').width('100%')

          Text(appState.getChatTaskContext()).fontSize(12).fontColor('#2563EB')
            .width('100%').padding(10).backgroundColor('#EFF6FF').borderRadius(10)

          this.ApiPlanCard()

          Column({ space: 4 }) {
            Text('课程与 DDL 日程').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
            Text('以下日程根据已导入课程、DDL 和可用时间生成，用于安排当前学习计划的执行时间。')
              .fontSize(12).fontColor('#667085').lineHeight(18).width('100%')
          }.width('100%')

          // ===== 本周概览 =====
          Row({ space: 10 }) {
            this.Summary(`${this.plan().tasks.length}`, '日程任务')
            this.Summary(`${appState.getPlanProgress()}%`, '日程进度')
            this.Summary(`${appState.getUrgentDDLs().length}`, '临近 DDL')
          }.width('100%')

          // ===== 周日期范围 =====
          Row() {
            Text(`📅 ${DateHelper.getWeekRangeLabel()}`)
              .fontSize(12).fontColor('#2563EB').fontWeight(FontWeight.Medium)
            Text(`今天 ${DateHelper.getTodayDayOfWeek()}`)
              .fontSize(11).fontColor('#667085')
              .backgroundColor('#EFF6FF').borderRadius(8)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          }.width('100%')

          // ===== Agent 决策依据 =====
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              Text('日程排序依据').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#1F2937')
              Text('本地日程').fontSize(10).fontColor('#2563EB').backgroundColor('#EFF6FF').borderRadius(8).padding({ left: 6, right: 6, top: 3, bottom: 3 })
            }.width('100%')
            Text(this.plan().decisionTrace.urgencyReason).fontSize(12).fontColor('#475467').lineHeight(18)
            Text(this.plan().decisionTrace.weaknessReason).fontSize(12).fontColor('#475467').lineHeight(18)
            Text(this.plan().decisionTrace.timeReason).fontSize(12).fontColor('#475467').lineHeight(18)
          }.width('100%').padding(16).backgroundColor('#EFF6FF').borderRadius(16)

          // ===== 计划调整提示 =====
          if (this.plan().adjustmentMessage.length > 0) {
            Text('最新调整：' + this.plan().adjustmentMessage).fontSize(12).fontColor('#2563EB').lineHeight(18)
              .width('100%').padding(12).backgroundColor('#FFFFFF').border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
          }

          // ===== 日期标签滚动栏（真实日历） =====
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.weekDays, (day: WeekDay) => {
                this.DayTab(day)
              }, (day: WeekDay) => day.dateStr)
            }.padding({ left: 1, right: 1 })
          }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')

          // ===== 当前日期任务列表 =====
          Row() {
            Text(`${this.activeDay} 的任务`)
              .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1F2937')
            if (this.isActiveDayToday()) {
              Text('今天').fontSize(10).fontColor('#FFFFFF')
                .backgroundColor('#2563EB').borderRadius(8)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            }
          }.width('100%')

          if (this.currentTasks().length === 0) {
            Column({ space: 8 }) {
              Text('📭').fontSize(32)
              Text('这一天暂未安排任务').fontSize(14).fontWeight(FontWeight.Medium).fontColor('#667085')
              Text('Agent 会根据你的完成进度补充安排，或切换到其他日期查看计划。')
                .fontSize(12).fontColor('#98A2B3').lineHeight(18)
            }.width('100%').padding(24).backgroundColor('#FFFFFF').borderRadius(14).alignItems(HorizontalAlign.Center)
          } else {
            ForEach(this.currentTasks(), (task: LearningPlanTask) => {
              this.TaskCard(task)
            }, (task: LearningPlanTask) => task.id)
          }

          // ===== 底部导航按钮 =====
          Button('确认计划').width('100%').height(48).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            .backgroundColor('#2563EB').borderRadius(14).margin({ top: 6, bottom: 20 })
            .onClick(() => this.completePlan())
        }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 96 })
      }.layoutWeight(1)
    }.width('100%').height('100%').backgroundColor('#F7F8FA')
    AIFloatButton()
    }.width('100%').height('100%')
  }

  @Builder
  Summary(value: string, label: string) {
    Column({ space: 4 }) {
      Text(value).fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1F2937')
      Text(label).fontSize(11).fontColor('#667085')
    }.layoutWeight(1).alignItems(HorizontalAlign.Center).padding({ top: 13, bottom: 13 }).backgroundColor('#FFFFFF').borderRadius(14)
  }
}
