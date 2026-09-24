import router from '@ohos.router';
import { appState } from '../data/AppState';
import { DecisionFactor, LearningPlan, PlanTask } from '../api/ApiModels';
import { FocusTask } from '../models/AgentModels';
import { PlanViewModel } from '../viewmodels/PlanViewModel';
import { FactorBreakdownCard } from '../components/FactorBreakdownCard';
import { AIFloatButton } from '../components/AIFloatButton';

@Entry
@Component
struct StudySuggestion {
  @State isLoading: boolean = true;
  @State plan: LearningPlan | null = null;
  @State errorMessage: string = '';
  private planViewModel: PlanViewModel = new PlanViewModel();
  private requestVersion: number = 0;
  private isPageActive: boolean = false;

  aboutToAppear(): void { this.isPageActive = true; this.loadSuggestion(); }
  aboutToDisappear(): void { this.isPageActive = false; this.requestVersion++; }

  private async loadSuggestion(forceRefresh: boolean = false): Promise<void> {
    if (this.isLoading && forceRefresh) return;
    this.isLoading = true;
    const requestVersion: number = ++this.requestVersion;
    const state = await this.planViewModel.load(forceRefresh);
    if (!this.isPageActive || requestVersion !== this.requestVersion) return;
    this.plan = state.plan;
    this.errorMessage = state.errorMessage;
    this.isLoading = false;
  }

  private currentTask(): PlanTask | null {
    if (this.plan === null || this.plan.tasks.length === 0) return null;
    for (let index: number = 0; index < this.plan.tasks.length; index++) {
      if (this.plan.tasks[index].status !== 'completed') return this.plan.tasks[index];
    }
    return this.plan.tasks[0];
  }

  private factors(): DecisionFactor[] { return this.plan?.factors ?? []; }
  private goBack(): void { appState.leaveChatTask(); router.back(); }

  private startSuggestedFocus(): void {
    const task: PlanTask | null = this.currentTask();
    if (task === null) return;
    appState.setFocusTask({ course: '专项学习', task: task.knowledgePointName,
      plannedMinutes: task.durationMinutes, source: 'agent', mode: 'normal', timerType: 'countdown',
      planTaskId: task.taskId } as FocusTask);
    router.pushUrl({ url: 'pages/FocusSetup' });
  }

  @Builder
  SuggestionCard(task: PlanTask) {
    Column({ space: 12 }) {
      Row() {
        Text('Agent 建议').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#172033').layoutWeight(1)
        Text(task.priority === 'high' ? '高优先级' : '当前任务').fontSize(12).fontColor('#FFFFFF')
          .backgroundColor(task.priority === 'high' ? '#DC2626' : '#2563EB')
          .borderRadius(14).padding({ left: 10, right: 10, top: 5, bottom: 5 })
      }.width('100%')
      Text(this.plan?.reason ?? 'Agent 已根据当前画像生成学习任务。')
        .fontSize(15).fontColor('#4B5565').lineHeight(22).width('100%')
      Column({ space: 8 }) {
        Text(`知识点：${task.knowledgePointName}`).fontSize(14).fontColor('#344054').width('100%')
        Text(`建议时长：${task.durationMinutes} 分钟`).fontSize(14).fontColor('#344054').width('100%')
        Text(`计划版本：V${this.plan?.version ?? 0}`).fontSize(14).fontColor('#344054').width('100%')
        Text(`基于画像版本：${this.plan?.generatedFromProfileVersion ?? 0}`).fontSize(14).fontColor('#344054').width('100%')
      }.width('100%').padding(12).backgroundColor('#F8FAFC').borderRadius(10)
      Button('立即专注').width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(14).onClick(() => this.startSuggestedFocus())
    }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
      .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 6 })
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('← 返回').fontSize(14).fontColor('#64748B').fontWeight(FontWeight.Medium).onClick(() => this.goBack())
          Blank()
          Text('学习建议').fontSize(13).fontColor('#2563EB').fontWeight(FontWeight.Bold)
        }.width('100%').padding({ left: 20, right: 20, top: 14, bottom: 14 }).backgroundColor('#FFFFFF')
        Scroll() {
          Column({ space: 16 }) {
            Text('今日学习建议').fontSize(26).fontWeight(FontWeight.Bold).fontColor('#172033').width('100%')
            Text('任务、时长和判断依据均来自当前 Agent 计划，前端不重新计算优先级。')
              .fontSize(13).fontColor('#667085').lineHeight(20).width('100%')
            if (this.isLoading) {
              Column({ space: 10 }) {
                LoadingProgress().width(34).height(34).color('#2563EB')
                Text('正在读取 Agent 计划…').fontSize(14).fontColor('#667085')
              }.width('100%').padding(32).alignItems(HorizontalAlign.Center)
            } else if (this.currentTask() !== null) {
              this.SuggestionCard(this.currentTask()!)
              if (this.factors().length > 0) {
                FactorBreakdownCard({ factors: this.factors(), reason: this.plan?.reason ?? '' })
              }
              Text(`${this.plan!.tasks.length} 项任务已按 Agent 计划排序`).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
              ForEach(this.plan!.tasks, (task: PlanTask, index: number) => {
                Row({ space: 10 }) {
                  Text(`${index + 1}`).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                    .width(24).height(24).textAlign(TextAlign.Center).backgroundColor('#2563EB').borderRadius(12)
                  Column({ space: 3 }) {
                    Text(task.knowledgePointName).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#1F2937')
                    Text(`${task.durationMinutes} 分钟 · ${task.status}`).fontSize(12).fontColor('#667085')
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                }.width('100%').padding(13).backgroundColor('#FFFFFF').borderRadius(12)
              }, (task: PlanTask) => task.taskId)
            } else {
              Column({ space: 10 }) {
                Text('暂时无法读取学习建议').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#B45309')
                Text(this.errorMessage.length > 0 ? this.errorMessage : '当前计划没有可执行任务。').fontSize(13).fontColor('#667085').lineHeight(20)
                Button('重新加载').height(44).fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(12)
                  .onClick(() => this.loadSuggestion(true))
              }.width('100%').padding(20).backgroundColor('#FFFFFF').borderRadius(16)
            }
          }.width('100%').padding({ left: 20, right: 20, top: 16, bottom: 96 })
        }.layoutWeight(1).backgroundColor('#F5F7FA')
      }.width('100%').height('100%')
      AIFloatButton()
    }.width('100%').height('100%')
  }
}
