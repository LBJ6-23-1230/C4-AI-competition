import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { AIFloatButton } from '../components/AIFloatButton';
import { ExerciseSubmissionResult, TraceEvent, TraceResponse, WorkflowResponse } from '../api/ApiModels';
import { TraceViewModel } from '../viewmodels/TraceViewModel';
import { ClientCache } from '../cache/ClientCache';
import { WorkflowSessionStore } from '../cache/WorkflowSessionStore';
import { ApiDisplayFormatter } from '../utils/ApiDisplayFormatter';
import { AgentApiClient } from '../api/AgentApiClient';

@Entry
@Component
struct AgentTrace {
  @State isLoading: boolean = true;
  @State isResetting: boolean = false;
  @State message: string = '';
  @State events: TraceEvent[] = [];
  @State traceId: string = '';
  @State expandedStateVersions: number[] = [];
  private viewModel: TraceViewModel = new TraceViewModel();
  private traceRequestVersion: number = 0;
  private resetRequestVersion: number = 0;
  private isPageActive: boolean = false;

  aboutToAppear(): void {
    this.isPageActive = true;
    const workflow: WorkflowResponse | null = ClientCache.getWorkflow();
    const assessment: ExerciseSubmissionResult | null = ClientCache.getAssessment();
    const cachedTrace: TraceResponse | null = ClientCache.getTrace();
    if (assessment?.traceId !== undefined) {
      this.traceId = assessment.traceId;
    } else if (workflow !== null) {
      this.traceId = workflow.traceId;
    } else if (cachedTrace !== null) {
      this.traceId = cachedTrace.traceId;
    }
    this.loadTrace();
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.traceRequestVersion++;
    this.resetRequestVersion++;
  }

  private isFixture(): boolean {
    return AgentApiClient.getConfig().useFixture;
  }

  private async loadTrace(forceRefresh: boolean = false): Promise<void> {
    if (this.isLoading && forceRefresh) {
      return;
    }
    if (this.traceId.length === 0) {
      this.isLoading = false;
      this.events = [];
      this.message = '当前还没有可查看的 Agent 轨迹，请先从知识画像开始一次诊断。';
      return;
    }
    this.isLoading = true;
    this.message = '';
    const requestVersion: number = ++this.traceRequestVersion;
    const trace = await this.viewModel.load(this.traceId, forceRefresh);
    if (!this.isPageActive || requestVersion !== this.traceRequestVersion) {
      return;
    }
    if (trace === null) {
      this.events = [];
      this.expandedStateVersions = [];
      const detail: string = this.viewModel.getErrorMessage();
      this.message = detail.length > 0 ? `暂时无法读取 Agent 决策过程：${detail}` : '暂时无法读取 Agent 决策过程。';
    } else {
      const orderedEvents: TraceEvent[] = trace.events.slice().sort((left: TraceEvent, right: TraceEvent) =>
        left.stateVersion - right.stateVersion
      );
      this.events = orderedEvents;
      if (orderedEvents.length > 0 && this.expandedStateVersions.length === 0) {
        this.expandedStateVersions = [orderedEvents[orderedEvents.length - 1].stateVersion];
      }
    }
    this.isLoading = false;
  }

  private isExpanded(stateVersion: number): boolean {
    return this.expandedStateVersions.indexOf(stateVersion) !== -1;
  }

  private toggleExpanded(stateVersion: number): void {
    if (this.isExpanded(stateVersion)) {
      this.expandedStateVersions = this.expandedStateVersions.filter((value: number) => value !== stateVersion);
      return;
    }
    this.expandedStateVersions = this.expandedStateVersions.concat([stateVersion]);
  }

  private statusTextColor(status: string): string {
    return status === 'failed' ? '#B42318' : '#0F766E';
  }

  private statusBackgroundColor(status: string): string {
    return status === 'failed' ? '#FEF3F2' : '#ECFDF5';
  }

  private async resetDemo(): Promise<void> {
    if (this.isResetting || !this.isFixture()) {
      return;
    }
    this.isResetting = true;
    const requestVersion: number = ++this.resetRequestVersion;
    const resetResult = await this.viewModel.reset();
    if (!this.isPageActive || requestVersion !== this.resetRequestVersion) {
      return;
    }
    if (resetResult === null) {
      this.isResetting = false;
      this.message = '重置失败，请稍后重试。';
      return;
    }
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    WorkflowSessionStore.clear(context);
    this.traceId = resetResult.traceId;
    await this.loadTrace(true);
    this.isResetting = false;
    this.message = '演示已重置：再次进入知识画像时将从掌握度 42 开始。';
  }

  @Builder
  TraceCard(event: TraceEvent, index: number) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(`${index + 1}`).fontSize(12).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          .width(24).height(24).textAlign(TextAlign.Center).backgroundColor('#2563EB').borderRadius(12)
        Text(ApiDisplayFormatter.agent(event.agent)).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#111827')
        Text(ApiDisplayFormatter.workflowStatus(event.status)).fontSize(11).fontColor(this.statusTextColor(event.status))
          .backgroundColor(this.statusBackgroundColor(event.status)).borderRadius(8)
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
      }.width('100%')
      Text(`执行动作：${ApiDisplayFormatter.tools(event.toolCalls)}`).fontSize(13).fontColor('#2563EB')
      if (this.isExpanded(event.stateVersion)) {
        Text(`输入：${event.inputSummary}`).fontSize(13).fontColor('#475467').lineHeight(19)
        Text(`结论：${event.outputSummary}`).fontSize(13).fontColor('#475467').lineHeight(19)
        if (event.evidenceIds.length > 0) {
          Text(`关联证据：${event.evidenceIds.join('、')}`).fontSize(12).fontColor('#667085').lineHeight(18)
        }
      }
      Row() {
        Text(`状态版本 ${event.stateVersion} · ${ApiDisplayFormatter.timestamp(event.timestamp)}`).fontSize(11).fontColor('#98A2B3')
        Blank()
        Text(this.isExpanded(event.stateVersion) ? '收起详情 ↑' : '展开详情 ↓')
          .fontSize(11).fontWeight(FontWeight.Medium).fontColor('#2563EB')
      }.width('100%').onClick(() => this.toggleExpanded(event.stateVersion))
    }.width('100%').padding(15).backgroundColor('#FFFFFF').border({ width: 1, color: '#E2E8F0' }).borderRadius(14)
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('← 返回').fontSize(14).fontColor('#64748B').onClick(() => router.back())
          Blank()
          Text('Agent Trace').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB')
        }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 }).backgroundColor('#FFFFFF')

        Scroll() {
          Column({ space: 16 }) {
            Text('Agent 的决策过程').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#111827').width('100%')
            Text('这里展示后端返回的决策记录，用于说明 Agent 为什么给出当前学习动作。')
              .fontSize(13).fontColor('#667085').lineHeight(19).width('100%')
            Text('不记录模型思维链，只展示可复核的决策依据、工具调用与状态版本。')
              .fontSize(12).fontColor('#0F766E').lineHeight(18).width('100%').padding(10).backgroundColor('#ECFDF5').borderRadius(10)
            Row() {
              Text(`Trace ID：${this.traceId}`).fontSize(12).fontColor('#64748B')
              Blank()
              Text(this.isLoading ? '刷新中…' : '刷新').fontSize(13)
                .fontColor(this.isLoading ? '#98A2B3' : '#2563EB')
                .onClick(() => this.loadTrace(true))
            }.width('100%').padding(12).backgroundColor('#FFFFFF').borderRadius(10)
            if (this.isLoading) {
              LoadingProgress().width(36).height(36).margin({ top: 30 })
            } else {
              ForEach(this.events, (event: TraceEvent, index: number) => {
                this.TraceCard(event, index)
              }, (event: TraceEvent) => `${event.agent}-${event.stateVersion}`)
              if (this.message.length > 0) {
                Text(this.message).fontSize(13).fontColor('#0F766E').width('100%').padding(12).backgroundColor('#ECFDF5').borderRadius(10)
              }
              if (this.events.length === 0) {
                Button('重新加载轨迹')
                  .width('100%').height(44).fontSize(14).fontColor('#2563EB').backgroundColor('#FFFFFF')
                  .border({ width: 1, color: '#BFDBFE' }).borderRadius(12).onClick(() => this.loadTrace(true))
              }
              if (this.isFixture()) {
                Button(this.isResetting ? '正在重置…' : '重置演示数据')
                  .width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                  .backgroundColor('#2563EB').borderRadius(12).enabled(!this.isResetting && !this.isLoading).onClick(() => this.resetDemo())
                Text('重置只清除本次演示的临时数据，不会删除项目代码。')
                  .fontSize(12).fontColor('#667085').textAlign(TextAlign.Center).width('100%')
                Button('查看重置后的知识画像')
                  .width('100%').height(44).fontSize(14).fontColor('#2563EB').backgroundColor('#FFFFFF')
                  .border({ width: 1, color: '#BFDBFE' }).borderRadius(12).onClick(() => router.pushUrl({ url: 'pages/StudyTags' }))
              }
            }
          }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 96 })
        }.layoutWeight(1).backgroundColor('#F3F6FA')
      }.width('100%').height('100%')
      AIFloatButton()
    }.width('100%').height('100%')
  }
}
