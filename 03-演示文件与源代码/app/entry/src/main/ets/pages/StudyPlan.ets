import router from '@ohos.router';
import { appState } from '../data/AppState';
import { FocusTask } from '../models/AgentModels';
import { AIFloatButton } from '../components/AIFloatButton';
import { LearningPlan, PlanTask } from '../api/ApiModels';
import { PlanViewModel } from '../viewmodels/PlanViewModel';

/** Displays the authoritative plan returned by the workflow API. */
@Entry
@Component
struct StudyPlan {
  @State isApiPlanLoading: boolean = true;
  @State apiPlan: LearningPlan | null = null;
  @State apiPlanMessage: string = '';
  private planViewModel: PlanViewModel = new PlanViewModel();
  private planRequestVersion: number = 0;
  private isPageActive: boolean = false;

  aboutToAppear(): void {
    this.isPageActive = true;
    this.loadCurrentPlan();
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.planRequestVersion++;
  }

  private async loadCurrentPlan(forceRefresh: boolean = false): Promise<void> {
    if (this.isApiPlanLoading && forceRefresh) return;
    const requestVersion: number = ++this.planRequestVersion;
    this.isApiPlanLoading = true;
    const state = await this.planViewModel.load(forceRefresh);
    if (!this.isPageActive || requestVersion !== this.planRequestVersion) return;
    this.apiPlan = state.plan;
    this.apiPlanMessage = state.errorMessage;
    this.isApiPlanLoading = false;
  }

  private startTask(task: PlanTask): void {
    appState.setFocusTask({
      course: '专项学习', task: task.knowledgePointName, plannedMinutes: task.durationMinutes,
      source: 'agent', mode: 'normal', timerType: 'countdown', planTaskId: task.taskId
    } as FocusTask);
    router.pushUrl({ url: 'pages/FocusSetup' });
  }

  private goBack(): void {
    appState.leaveChatTask();
    router.back();
  }

  private completePlan(): void {
    appState.completeChatTask(
      '当前学习计划已确认。',
      '从第一项专项任务开始，完成后 Agent 会基于新的学习证据更新计划。',
      '查看当前计划',
      'pages/StudyPlan'
    );
    router.back();
  }

  /**
   * 任务状态文案。
   *
   * ⚠️ 必须问 `appState`：接口**不会**回写 `task.status`（后端没有这个接口），
   * 完成状态只存在本地（专注结算时写入）。只按 `task.status` 渲染的话，
   * 用户做完专注回到计划页，任务卡仍然写着「待执行」—— 与「我的」里的
   * 任务完成度互相打架（实测反馈：「为什么无法读取更新后的学习计划」）。
   */
  private taskStatusLabel(task: PlanTask): string {
    if (appState.isTaskCompleted(task.taskId, task.status)) return '已完成';
    if (task.status === 'in_progress') return '进行中';
    return '待执行';
  }

  @Builder
  PlanTaskCard(task: PlanTask) {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 4 }) {
          Text(task.knowledgePointName).fontSize(17).fontWeight(FontWeight.Bold).fontColor('#1F2937').maxLines(2)
          Text(`${task.durationMinutes} 分钟专项练习`).fontSize(12).fontColor('#667085')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text(this.taskStatusLabel(task)).fontSize(11).fontWeight(FontWeight.Medium)
          .fontColor('#2563EB').backgroundColor('#EFF6FF').borderRadius(10).padding({ left: 8, right: 8, top: 4, bottom: 4 })
      }.width('100%')
      if (task.priority !== undefined) {
        Text(task.priority === 'high' ? 'Agent 优先处理' : `优先级：${task.priority}`)
          .fontSize(12).fontColor('#475467').width('100%')
      }
      // 已完成的任务不再给「开始任务」—— 判据与上面那行文案**同源**（都走 appState）。
      if (!appState.isTaskCompleted(task.taskId, task.status)) {
        Button('开始任务').width('100%').height(42).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          .backgroundColor('#2563EB').borderRadius(12).onClick(() => this.startTask(task))
      }
    }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18).border({ width: 1, color: '#EAECF0' })
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('← 返回').fontSize(14).fontColor('#64748B').fontWeight(FontWeight.Medium).onClick(() => this.goBack())
          Blank()
          Text('当前学习计划').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB')
        }.width('100%').padding({ left: 20, right: 20, top: 18, bottom: 14 }).backgroundColor('#FFFFFF')
        Scroll() {
          Column({ space: 16 }) {
            Row() {
              Text('Agent 学习计划').fontSize(25).fontWeight(FontWeight.Bold).fontColor('#1F2937')
              Blank()
              if (this.apiPlan !== null) {
                Text(`Plan V${this.apiPlan.version}`).fontSize(12).fontWeight(FontWeight.Bold).fontColor('#2563EB')
                  .backgroundColor('#EFF6FF').borderRadius(9).padding({ left: 8, right: 8, top: 4, bottom: 4 })
              }
            }.width('100%')
            Text('任务、优先级和时长均以当前工作流接口返回为准；本地课程与 DDL 日程不会覆盖此计划。')
              .fontSize(13).fontColor('#667085').lineHeight(20).width('100%')
            Text(appState.getChatTaskContext()).fontSize(12).fontColor('#2563EB')
              .width('100%').padding(10).backgroundColor('#EFF6FF').borderRadius(10)
            if (this.isApiPlanLoading) {
              Column({ space: 10 }) {
                LoadingProgress().width(30).height(30).color('#2563EB')
                Text('正在读取当前计划…').fontSize(14).fontColor('#667085')
              }.width('100%').padding(32).alignItems(HorizontalAlign.Center).backgroundColor('#FFFFFF').borderRadius(16)
            } else if (this.apiPlan !== null) {
              if (this.apiPlan.reason !== undefined) {
                Column({ space: 6 }) {
                  Text('本次计划依据').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#1F2937')
                  Text(this.apiPlan.reason).fontSize(13).fontColor('#475467').lineHeight(20)
                  Text(`基于画像版本 ${this.apiPlan.generatedFromProfileVersion} 生成`).fontSize(12).fontColor('#667085')
                }.width('100%').padding(16).backgroundColor('#EFF6FF').borderRadius(16)
              }
              Text(`${this.apiPlan.tasks.length} 项当前任务`).fontSize(17).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
              if (this.apiPlan.tasks.length === 0) {
                Text('Agent 暂未安排任务，请刷新计划或稍后重试。').fontSize(14).fontColor('#667085')
                  .width('100%').padding(22).backgroundColor('#FFFFFF').borderRadius(14)
              } else {
                ForEach(this.apiPlan.tasks, (task: PlanTask) => {
                  this.PlanTaskCard(task)
                }, (task: PlanTask) => `${task.taskId}-${task.status}`)
              }
            } else {
              Column({ space: 10 }) {
                Text(this.apiPlanMessage.length > 0 ? this.apiPlanMessage : '暂时无法读取当前计划。')
                  .fontSize(14).fontColor('#B45309').lineHeight(20)
                // 原来这句写死"请确认服务地址"，但失败原因未必是地址 ——
                // 也可能是"这个账号还没有计划"（后端 NOT_FOUND）。一律甩给地址会带偏排查方向。
                Text('若刚切换过后端地址，请确认地址可访问；也可能是本账号暂无计划。页面不会改用本地计划替代接口结果。')
                  .fontSize(12).fontColor('#667085')
              }.width('100%').padding(18).backgroundColor('#FFFBEB').borderRadius(14)
            }
            Button(this.isApiPlanLoading ? '正在刷新…' : '刷新当前计划').width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold)
              .fontColor('#2563EB').backgroundColor('#FFFFFF').border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
              .enabled(!this.isApiPlanLoading).onClick(() => this.loadCurrentPlan(true))
            if (this.apiPlan !== null) {
              Button('确认计划').width('100%').height(48).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                .backgroundColor('#2563EB').borderRadius(14).margin({ bottom: 20 }).onClick(() => this.completePlan())
            }
          }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 96 })
        }.layoutWeight(1).backgroundColor('#F7F8FA')
      }.width('100%').height('100%')
      AIFloatButton()
    }.width('100%').height('100%')
  }
}
