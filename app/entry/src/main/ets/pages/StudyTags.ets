import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { appState } from '../data/AppState';
import { AIFloatButton } from '../components/AIFloatButton';
import { RadarChart } from '../components/RadarChart';
import { Evidence, KnowledgeMastery, MasteryHistory } from '../api/ApiModels';
import { DemoSnapshot } from '../cache/DemoSnapshot';
import { ProfileViewModel } from '../viewmodels/ProfileViewModel';
import { WorkflowViewModel } from '../viewmodels/WorkflowViewModel';
import { WorkflowSessionStore } from '../cache/WorkflowSessionStore';
import { ApiDisplayFormatter } from '../utils/ApiDisplayFormatter';
import { FollowUpCard } from '../components/FollowUpCard';

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
  @State expandedHistoryTimestamp: string = '';
  @State chartDims: string[] = [];
  @State chartCurrent: number[] = [];
  @State chartTarget: number[] = [];
  @State chartWeak: number[] = [];
  @State chartStrong: number[] = [];

  /**
   * 把"最弱的那个知识点"翻译成一句人话，作为「接下来」卡片的理由。
   * 取掌握度最低的一项；没有数据时给保守兜底文案，不留空白。
   */
  private weaknessSummary(): string {
    if (this.mastery.length === 0) {
      return '还没有足够的学情数据。先做一轮诊断练习，Agent 才能算出你的薄弱点。';
    }
    let weakest: KnowledgeMastery = this.mastery[0];
    for (let index: number = 1; index < this.mastery.length; index++) {
      if (this.mastery[index].masteryScore < weakest.masteryScore) {
        weakest = this.mastery[index];
      }
    }
    return `当前最薄弱的是「${weakest.knowledgePointName}」，掌握度 ${weakest.masteryScore}。`
      + '专项练习是拉高它最快的路径。';
  }
  private viewModel: ProfileViewModel = new ProfileViewModel();
  private workflowViewModel: WorkflowViewModel = new WorkflowViewModel();
  private profileRequestVersion: number = 0;
  private workflowRequestVersion: number = 0;
  private isPageActive: boolean = false;

  aboutToAppear(): void {
    this.isPageActive = true;
    this.loadProfile();
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.profileRequestVersion++;
    this.workflowRequestVersion++;
  }

  /**
   * 当前身份对应的 userId。
   *
   * 已登录 → 真实 userId；游客/离线 → `demo-user`（它本来就是体验身份）。
   * 页面里**不允许再写死 `demo-user`** —— 那是"登录后仍看到演示数据"的根因。
   */
  private effectiveUserId(): string {
    const id: string = appState.currentUser.userId;
    return id.length > 0 ? id : DemoSnapshot.USER_ID;
  }

  private async loadProfile(forceRefresh: boolean = false): Promise<void> {
    if (this.isLoading && forceRefresh) {
      return;
    }
    const requestVersion: number = ++this.profileRequestVersion;
    this.isLoading = true;
    // 读**当前身份**的画像，而不是写死的演示账号。
    //
    // 修复的缺陷：这里原先硬编码 `DemoSnapshot.USER_ID`（= demo-user），
    // 于是用户注册登录后，画像页展示的仍是演示账号的掌握度（42），
    // 而不是自己的（新账号是 0）。后端侧同步修了身份解析，
    // 两边都改才生效。
    //
    // 注意游客/离线态下 `appState.currentUser.userId` 本来就是 demo-user，
    // 所以演示基线不受影响。
    const state = await this.viewModel.load(this.effectiveUserId(), forceRefresh);
    if (!this.isPageActive || requestVersion !== this.profileRequestVersion) {
      return;
    }
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
    const requestVersion: number = ++this.workflowRequestVersion;
    const workflow = await this.workflowViewModel.start(this.goal, this.userId);
    if (!this.isPageActive || requestVersion !== this.workflowRequestVersion) {
      return;
    }
    this.isStartingWorkflow = false;
    if (workflow === null) {
      this.workflowErrorMessage = this.workflowViewModel.getErrorMessage() || 'Agent 会话启动失败，请稍后重试。';
      return;
    }
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    // 带上归属身份：冷启动恢复时靠它判断这个会话是不是当前用户的。
    WorkflowSessionStore.save(context, workflow, appState.currentUser.userId);
    await this.workflowViewModel.runUntilComplete(1);
    if (!this.isPageActive || requestVersion !== this.workflowRequestVersion) {
      return;
    }
    router.pushUrl({ url: 'pages/ExercisePractice' });
  }

  private buildChartData(): void {
    // 最多 6 个维度：雷达图再密就看不清标签了
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

    // ⚠️ 下面三段是补上的。原先这里只填了 dims/current，
    // 而 `target` / `weakIndices` / `strengthIndices` 三个数组
    // **声明了、传给组件了、却从未赋值**，永远是空数组 ——
    // 于是雷达图里三条与之相关的绘制分支全是死代码：
    //   · 「目标水平(灰虚线)」：组件判 `target.length === n`，空数组长度为 0 必不成立
    //   · 最薄弱点标红（半径 7 的红点）
    //   · 最强点标深蓝
    // 图还是画得出来（网格/轴线/当前水平/标签都正常），
    // 所以只看截图看不出问题 —— 属于"画了但少画了三样"。

    // 目标线：从学习目标文案里取"80+"这类分数，取不到就用 80
    // （示例目标为「数据结构期末80+」）。
    const targetValue: number = StudyTags.parseTargetScore(this.goal);
    for (let index: number = 0; index < items.length; index++) {
      this.chartTarget.push(targetValue);
    }

    // 最薄弱 / 最强：按本次展示的维度里取极值。
    // 只在维度数 >= 2 时才标 —— 单点时"最弱"和"最强"是同一个，标红没有信息量。
    if (items.length >= 2) {
      let weakest: number = 0;
      let strongest: number = 0;
      for (let index: number = 1; index < items.length; index++) {
        if (items[index].masteryScore < items[weakest].masteryScore) {
          weakest = index;
        }
        if (items[index].masteryScore > items[strongest].masteryScore) {
          strongest = index;
        }
      }
      // 掌握度全相同（并列）时不标任何点，避免随便挑一个标红造成误导
      if (items[weakest].masteryScore !== items[strongest].masteryScore) {
        this.chartWeak = [weakest];
        this.chartStrong = [strongest];
      }
    }
  }

  /**
   * 从学习目标文案里取目标分数。
   *
   * 支持「数据结构期末80+」「目标 85 分」「冲刺90」这几种写法。
   * 取不到就返回 80 —— 与后端演示基线（`data/repository.json` 的
   * 示例目标「数据结构期末80+」）一致，而不是随手写一个值。
   */
  private static parseTargetScore(goal: string): number {
    const matched: RegExpMatchArray | null = goal.match(/(\d{2,3})/);
    if (matched === null) {
      return 80;
    }
    const value: number = Number(matched[1]);
    if (!Number.isFinite(value) || value < 1 || value > 100) {
      return 80;
    }
    return value;
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

  private isHistoryExpanded(item: MasteryHistory): boolean {
    return this.expandedHistoryTimestamp === item.timestamp;
  }

  private toggleHistoryEvidence(item: MasteryHistory): void {
    this.expandedHistoryTimestamp = this.isHistoryExpanded(item) ? '' : item.timestamp;
  }

  private evidenceForHistory(item: MasteryHistory): Evidence[] {
    return this.evidence.filter((evidence: Evidence) => item.evidenceIds.indexOf(evidence.id) !== -1);
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

              // 实测反馈：「学习画像和学情画像有什么区别？点开之后跳转的界面是一样的」。
              // 它们确实是**同一页** —— 数据只有一份，差别只在"看"还是"改"。
              // 与其让用户猜，不如在页面上直接讲清楚。
              Text('本页同时是「学情画像」与「学习画像」：前者在对话里用来查看掌握度；'
                + '后者在你更新学习档案（目标 / 掌握情况）之后回到这里核对结果。两者读的是同一份数据。')
                .fontSize(11).fontColor('#98A2B3').lineHeight(17).width('100%')

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
                    // 雷达图**不是没触发，而是维度不够**：至少要三个轴才成形，
                    // 两个点连起来只是一条线。实测反馈「之前初赛版本在学情画像内有
                    // 雷达图的，现在始终没有触发」—— 根因在这里（以及演示画像里
                    // 原先只预置了 1 个知识点，见 server 的 `app/api/demo.py`）。
                    // 与其让用户以为坏了，不如说清触发条件与达成路径。
                    Text(`雷达图需要至少 3 个知识点才成形（当前 ${this.mastery.length} 个），`
                      + '所以先用进度卡展示。做几轮其他知识点的专项练习、掌握度积累到 3 个以上后，'
                      + '这里会自动切换成雷达图。')
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
                          Text(`置信度 ${item.confidence} · 最近更新 ${ApiDisplayFormatter.timestamp(item.lastUpdated)}`)
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
                    Column({ space: 8 }) {
                      Row() {
                        Text(`${item.oldScore} → ${item.newScore} · 来源：${ApiDisplayFormatter.evidenceSource(item.source)}`)
                          .fontSize(14).fontColor('#1F2937').layoutWeight(1)
                        Text(this.isHistoryExpanded(item) ? '收起 ↑' : '查看证据 ↓')
                          .fontSize(12).fontWeight(FontWeight.Medium).fontColor('#2563EB')
                      }.width('100%').onClick(() => this.toggleHistoryEvidence(item))
                      if (this.isHistoryExpanded(item)) {
                        if (this.evidenceForHistory(item).length === 0) {
                          Text('该次变化暂未返回可展示的证据详情。').fontSize(12).fontColor('#667085')
                        } else {
                          ForEach(this.evidenceForHistory(item), (evidence: Evidence) => {
                            Text(`${ApiDisplayFormatter.evidenceSource(evidence.sourceType)} · ${ApiDisplayFormatter.metric(evidence.metric)} · ${this.evidenceValue(evidence)}`)
                              .fontSize(12).fontColor('#475467').lineHeight(18).width('100%')
                          }, (evidence: Evidence) => evidence.id)
                        }
                      }
                    }.width('100%').padding(12).backgroundColor('#EFF6FF').borderRadius(10)
                  }, (item: MasteryHistory) => item.timestamp)
                }
                .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
              }

              if (this.evidence.length > 0) {
                Column({ space: 10 }) {
                  Text('Evidence 学习证据').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#111827').width('100%')
                  ForEach(this.evidence, (item: Evidence) => {
                    Column({ space: 5 }) {
                      Text(`${ApiDisplayFormatter.evidenceSource(item.sourceType)} · ${ApiDisplayFormatter.metric(item.metric)}`).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#1F2937')
                      Text(`知识点：${ApiDisplayFormatter.knowledgePoint(item.knowledgePointId)} · 数值：${this.evidenceValue(item)}`)
                        .fontSize(12).fontColor('#475467')
                      Text(ApiDisplayFormatter.timestamp(item.timestamp)).fontSize(11).fontColor('#98A2B3')
                    }
                    .width('100%').padding(13).backgroundColor('#F8FAFC')
                    .border({ width: 1, color: '#E2E8F0' }).borderRadius(12)
                  }, (item: Evidence) => item.id)
                }
                .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
              }

              // ★ 画像是"诊断"，不是终点。
              // 重构前这一页只给「刷新画像」和「开始诊断练习」，看完雷达图就没了下文；
              // 用户知道了自己哪里弱，却拿不到一个"现在就去补"的动作。
              FollowUpCard({
                title: '接下来',
                reason: this.weaknessSummary(),
                primaryText: '按薄弱点开始专项练习',
                primaryTarget: 'pages/ExercisePractice',
                secondaryText: '看 Agent 如何重排计划',
                secondaryTarget: 'pages/StudyPlan'
              })

              Button('刷新画像')
                .fontSize(14).fontColor('#2563EB').backgroundColor('#FFFFFF')
                .border({ width: 1, color: '#BFDBFE' }).height(44).borderRadius(12).width('100%')
                .enabled(!this.isLoading && !this.isStartingWorkflow)
                .onClick(() => { this.loadProfile(true); })

              if (this.workflowErrorMessage.length > 0) {
                Text(this.workflowErrorMessage).fontSize(13).fontColor('#B45309').lineHeight(19)
                  .width('100%').padding(12).backgroundColor('#FFFBEB').borderRadius(10)
              }

              Button(this.isStartingWorkflow ? '正在启动 Agent 会话…' : '启动 Agent 诊断会话')
                .fontSize(15).fontWeight(FontWeight.Bold).fontColor('#2563EB').backgroundColor('#FFFFFF')
                .border({ width: 1, color: '#BFDBFE' })
                .height(46).borderRadius(12).width('100%').enabled(!this.isStartingWorkflow)
                .onClick(() => this.startDiagnosis())

              Button('💬 问知学Mate')
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
