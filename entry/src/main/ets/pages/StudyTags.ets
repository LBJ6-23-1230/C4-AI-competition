import router from '@ohos.router';
import { appState } from '../data/AppState';
import { AIFloatButton } from '../components/AIFloatButton';
import { RadarChart } from '../components/RadarChart';
import { Evidence, KnowledgeMastery, MasteryHistory } from '../api/ApiModels';
import { DemoSnapshot } from '../cache/DemoSnapshot';
import { ProfileViewModel } from '../viewmodels/ProfileViewModel';
import { WorkflowViewModel } from '../viewmodels/WorkflowViewModel';

@Entry
@Component
struct StudyTags {
  @State isLoading: boolean = true;
  @State errorMessage: string = '';
  @State workflowErrorMessage: string = '';
  @State isStartingWorkflow: boolean = false;
  @State userId: string = '';
  @State goal: string = '';
  @State profileVersion: number = 0;
  @State mastery: KnowledgeMastery[] = [];
  @State history: MasteryHistory[] = [];
  @State evidence: Evidence[] = [];
  @State chartDims: string[] = [];
  @State chartCurrent: number[] = [];
  @State chartTarget: number[] = [];
  @State chartWeak: number[] = [];
  @State chartStrong: number[] = [];
  private viewModel: ProfileViewModel = new ProfileViewModel();
  private workflowViewModel: WorkflowViewModel = new WorkflowViewModel();

  aboutToAppear(): void {
    this.loadProfile();
  }

  private async loadProfile(forceRefresh: boolean = false): Promise<void> {
    this.isLoading = true;
    const state = await this.viewModel.load(DemoSnapshot.USER_ID, forceRefresh);
    this.userId = state.userId;
    this.goal = state.goal;
    this.profileVersion = state.profileVersion;
    this.mastery = state.mastery;
    this.history = state.history;
    this.evidence = state.evidence;
    this.errorMessage = state.errorMessage;
    this.buildChartData();
    this.isLoading = false;
  }

  private async startDiagnosis(): Promise<void> {
    if (this.isStartingWorkflow) {
      return;
    }
    this.isStartingWorkflow = true;
    this.workflowErrorMessage = '';
    const workflow = await this.workflowViewModel.start(this.goal, this.userId);
    this.isStartingWorkflow = false;
    if (workflow === null) {
      this.workflowErrorMessage = this.workflowViewModel.getErrorMessage() || 'Agent 会话启动失败，请稍后重试。';
      return;
    }
    router.pushUrl({ url: 'pages/ExercisePractice' });
  }

  private buildChartData(): void {
    const items: KnowledgeMastery[] = this.mastery.slice(0, 6);
    this.chartDims = [];
    this.chartCurrent = [];
    this.chartTarget = [];
    this.chartWeak = [];
    this.chartStrong = [];

    for (let index: number = 0; index < items.length; index++) {
      this.chartDims.push(items[index].knowledgePointName);
      this.chartCurrent.push(items[index].masteryScore);
    }
  }

  private evidenceCount(knowledgePointId: string): number {
    let count: number = 0;
    for (let index: number = 0; index < this.evidence.length; index++) {
      if (this.evidence[index].knowledgePointId === knowledgePointId) {
        count++;
      }
    }
    return count;
  }

  private evidenceValue(evidence: Evidence): string {
    return JSON.stringify(evidence.value);
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('← 返回')
            .fontSize(14).fontColor('#64748B').fontWeight(FontWeight.Medium)
            .onClick(() => { router.back(); })
          Blank()
          Text(`知识画像 V${this.profileVersion}`)
            .fontSize(13).fontColor('#2563EB').fontWeight(FontWeight.Bold)
            .backgroundColor('#EFF6FF').borderRadius(16)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        }
        .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .backgroundColor('#FFFFFF')

        Scroll() {
          Column({ space: 16 }) {
            if (this.isLoading) {
              Column({ space: 10 }) {
                LoadingProgress().width(32).height(32)
                Text('正在读取学习画像…').fontSize(14).fontColor('#64748B')
              }
              .width('100%').padding(32).alignItems(HorizontalAlign.Center)
            } else {
              if (this.errorMessage.length > 0) {
                Text(this.errorMessage).fontSize(13).fontColor('#B45309').lineHeight(19)
                  .width('100%').padding(12).backgroundColor('#FFFBEB')
                  .border({ width: 1, color: '#FDE68A' }).borderRadius(12)
              }

              Column({ space: 8 }) {
                Text('当前学习目标').fontSize(13).fontColor('#64748B')
                Text(this.goal.length > 0 ? this.goal : '尚未建立学习目标')
                  .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#111827')
              }
              .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
              .shadow({ radius: 8, color: '#10000000', offsetX: 0, offsetY: 4 })

              if (this.mastery.length > 0) {
                if (this.mastery.length >= 3) {
                  Column({ space: 8 }) {
                    Text('知识掌握度').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#111827')
                    Text('蓝线表示后端返回的当前掌握度；分数不在前端重新计算。')
                      .fontSize(13).fontColor('#6B7280')
                    RadarChart({
                      dimensions: this.chartDims,
                      current: this.chartCurrent,
                      target: this.chartTarget,
                      weakIndices: this.chartWeak,
                      strengthIndices: this.chartStrong
                    })
                  }
                  .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
                  .shadow({ radius: 8, color: '#10000000', offsetX: 0, offsetY: 4 })
                } else {
                  Column({ space: 10 }) {
                    Text('当前掌握度').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#111827')
                    Text('当前只有少量知识点，使用进度卡展示会比雷达图更清晰。')
                      .fontSize(13).fontColor('#6B7280')
                    ForEach(this.mastery, (item: KnowledgeMastery) => {
                      Column({ space: 8 }) {
                        Row() {
                          Text(item.knowledgePointName).fontSize(15).fontWeight(FontWeight.Medium).fontColor('#1F2937').layoutWeight(1)
                          Text(`${item.masteryScore} / 100`).fontSize(17).fontWeight(FontWeight.Bold).fontColor('#2563EB')
                        }.width('100%')
                        Progress({ value: item.masteryScore, total: 100, type: ProgressType.Linear })
                          .color('#2563EB').backgroundColor('#DBEAFE').height(8).borderRadius(8)
                      }.width('100%').padding(12).backgroundColor('#F8FAFC').borderRadius(12)
                    }, (item: KnowledgeMastery) => item.knowledgePointId)
                  }
                  .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
                  .shadow({ radius: 8, color: '#10000000', offsetX: 0, offsetY: 4 })
                }

                Column({ space: 10 }) {
                  Text('掌握度明细').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#111827').width('100%')
                  ForEach(this.mastery, (item: KnowledgeMastery) => {
                    Column({ space: 8 }) {
                      Row() {
                        Column({ space: 4 }) {
                          Text(item.knowledgePointName).fontSize(15).fontWeight(FontWeight.Medium).fontColor('#1F2937')
                          Text(`置信度 ${item.confidence} · 最近更新 ${item.lastUpdated}`)
                            .fontSize(11).fontColor('#9CA3AF').maxLines(1)
                        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                        Text(`${item.masteryScore}`)
                          .fontSize(24).fontWeight(FontWeight.Bold).fontColor('#2563EB')
                        Text(' / 100').fontSize(12).fontColor('#64748B').margin({ top: 8 })
                      }.width('100%').alignItems(VerticalAlign.Top)
                      Progress({ value: item.masteryScore, total: 100, type: ProgressType.Linear })
                        .color('#2563EB').backgroundColor('#DBEAFE').height(8).borderRadius(8)
                      Text(`关联学习证据 ${this.evidenceCount(item.knowledgePointId)} 条`)
                        .fontSize(12).fontColor('#475467')
                    }
                    .width('100%').padding(14).backgroundColor('#F8FAFC')
                    .border({ width: 1, color: '#E2E8F0' }).borderRadius(12)
                  }, (item: KnowledgeMastery) => item.knowledgePointId)
                }
                .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
                .shadow({ radius: 8, color: '#10000000', offsetX: 0, offsetY: 4 })
              } else {
                Text('尚未建立知识画像。完成一次诊断或练习后，系统会在这里展示掌握度和证据。')
                  .fontSize(14).fontColor('#64748B').lineHeight(22)
                  .width('100%').padding(20).backgroundColor('#FFFFFF').borderRadius(16)
              }

              if (this.history.length > 0) {
                Column({ space: 10 }) {
                  Text('掌握度变化').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#111827').width('100%')
                  ForEach(this.history, (item: MasteryHistory) => {
                    Text(`${item.oldScore} → ${item.newScore} · 来源：${item.source}`)
                      .fontSize(14).fontColor('#1F2937').width('100%').padding(12)
                      .backgroundColor('#EFF6FF').borderRadius(10)
                  }, (item: MasteryHistory) => item.timestamp)
                }
                .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
              }

              if (this.evidence.length > 0) {
                Column({ space: 10 }) {
                  Text('Evidence 学习证据').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#111827').width('100%')
                  ForEach(this.evidence, (item: Evidence) => {
                    Column({ space: 5 }) {
                      Text(`${item.sourceType} · ${item.metric}`).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#1F2937')
                      Text(`知识点：${item.knowledgePointId} · 数值：${this.evidenceValue(item)}`)
                        .fontSize(12).fontColor('#475467')
                      Text(item.timestamp).fontSize(11).fontColor('#98A2B3')
                    }
                    .width('100%').padding(13).backgroundColor('#F8FAFC')
                    .border({ width: 1, color: '#E2E8F0' }).borderRadius(12)
                  }, (item: Evidence) => item.id)
                }
                .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
              }

              Button('刷新画像')
                .fontSize(14).fontColor('#2563EB').backgroundColor('#FFFFFF')
                .border({ width: 1, color: '#BFDBFE' }).height(44).borderRadius(12).width('100%')
                .onClick(() => { this.loadProfile(true); })

              if (this.workflowErrorMessage.length > 0) {
                Text(this.workflowErrorMessage).fontSize(13).fontColor('#B45309').lineHeight(19)
                  .width('100%').padding(12).backgroundColor('#FFFBEB').borderRadius(10)
              }

              Button(this.isStartingWorkflow ? '正在启动 Agent 会话…' : '开始诊断练习')
                .fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF').backgroundColor('#2563EB')
                .height(46).borderRadius(12).width('100%').enabled(!this.isStartingWorkflow)
                .onClick(() => this.startDiagnosis())

              Button('💬 问知学搭子')
                .fontSize(14).fontColor('#2563EB').backgroundColor('#FFFFFF')
                .border({ width: 1, color: '#BFDBFE' })
                .height(44).borderRadius(12).width('100%')
                .onClick(() => {
                  appState.setChatPrompt('帮我分析知识画像中的掌握度和学习证据');
                  router.pushUrl({ url: 'pages/ChatMain' });
                })
            }
          }
          .width('100%').padding({ left: 16, right: 16, top: 16, bottom: 96 })
        }
        .layoutWeight(1).backgroundColor('#F3F6FA')
      }
      .width('100%').height('100%')
      AIFloatButton()
    }.width('100%').height('100%')
  }
}
