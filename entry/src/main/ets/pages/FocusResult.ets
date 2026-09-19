import router from '@ohos.router';
import { appState } from '../data/AppState';
import { AgentFeedback, FocusSelfAssessment, FocusSession, FocusTask } from '../models/AgentModels';
import { LocalAgentService } from '../services/LocalAgentService';
import { AIFloatButton } from '../components/AIFloatButton';
import { ChatNavigation } from '../services/ChatNavigation';
import { AgentApiClient } from '../api/AgentApiClient';

@Entry
@Component
struct FocusResult {
  @State assessment: FocusSelfAssessment = 'completed';
  @State actualMinutes: number = 30;
  @State pauseCount: number = 0;
  @State interruptionCount: number = 0;
  @State saved: boolean = false;
  @State resultSession: FocusSession | null = null;
  private fallbackTaskId: string = `focus-${Date.now()}`;

  aboutToAppear(): void {
    if (appState.focusResultDraft !== null) {
      this.resultSession = appState.focusResultDraft;
      this.assessment = appState.focusResultDraft.selfAssessment;
      this.actualMinutes = appState.focusResultDraft.actualMinutes;
      this.pauseCount = appState.focusResultDraft.pauseCount;
      this.interruptionCount = appState.focusResultDraft.interruptionCount;
    }
  }

  private currentSession(): FocusSession {
    const draft: FocusSession | null = this.resultSession ?? appState.focusResultDraft;
    const focusTask: FocusTask | null = appState.activeFocusTask;
    const planned: number = draft?.plannedMinutes ?? focusTask?.plannedMinutes ?? 30;
    const actual: number = draft?.actualMinutes ?? this.actualMinutes;
    const timedRate: number = planned <= 0 ? (actual > 0 ? 100 : 0) : Math.min(100, Math.round(actual / planned * 100));
    let completionRate: number = 100;
    if (this.assessment === 'partial') {
      completionRate = Math.max(40, Math.min(89, timedRate));
    } else if (this.assessment === 'not_completed') {
      completionRate = Math.min(39, timedRate);
    }
    const status = this.assessment === 'completed' ? 'completed' :
      ((draft?.status === 'interrupted' || this.interruptionCount > 0) ? 'interrupted' : 'not_completed');
    return {
      taskId: draft?.taskId ?? this.fallbackTaskId,
      planTaskId: draft?.planTaskId ?? focusTask?.planTaskId,
      course: draft?.course ?? focusTask?.course ?? '数据结构',
      task: draft?.task ?? focusTask?.task ?? '理清二叉树中序遍历',
      plannedMinutes: planned, actualMinutes: actual,
      pauseCount: draft?.pauseCount ?? this.pauseCount,
      interruptionCount: draft?.interruptionCount ?? this.interruptionCount,
      completionRate: completionRate, selfAssessment: this.assessment,
      timerType: draft?.timerType ?? focusTask?.timerType ?? 'countdown',
      status: status,
      endedAt: draft?.endedAt ?? new Date().toLocaleString()
    };
  }

  private save(): void {
    if (this.saved) {
      return;
    }
    const session: FocusSession = this.currentSession();
    const inserted: boolean = appState.saveFocusSession(session);
    if (!inserted) {
      this.resultSession = session;
      this.saved = true;
      return;
    }
    if (this.isFixture()) {
      const currentPlan = appState.weeklyPlan ?? LocalAgentService.generateWeeklyPlan(
        appState.courses, appState.homeworkDDLs, appState.currentUser
      );
      appState.setWeeklyPlan(LocalAgentService.adjustPlanAfterFocus(currentPlan, session));
      appState.latestReview = LocalAgentService.generateReviewSummary(
        appState.latestSuggestion,
        appState.latestPartner,
        appState.latestWrongAnalysis
      );
    }
    appState.completeChatTask(
      this.isFixture() ?
        (this.assessment === 'completed' ? '本次专注已完成，离线计划已同步更新。' : '本次专注结果已保存，离线计划已调整。') :
        '本次专注结果已保存；后端尚未提供专注结果同步接口。',
      this.isFixture() ? '查看离线模式更新后的安排。' : '可继续查看后端当前计划。',
      '查看更新计划',
      'pages/StudyPlan'
    );
    this.resultSession = session;
    appState.clearFocusResultDraft();
    appState.clearFocusTask();
    this.saved = true;
  }

  private returnToChat(): void {
    ChatNavigation.returnToChat();
  }

  private isFixture(): boolean {
    return AgentApiClient.getConfig().useFixture;
  }

  private timerLabel(): string {
    return this.currentSession().timerType === 'stopwatch' ? '正计时' : '倒计时';
  }

  private statusLabel(): string {
    switch (this.currentSession().status) {
      case 'completed': return '已完成';
      case 'interrupted': return '已中断';
      default: return '未完成';
    }
  }

  build() {
    Stack() {
    Column() {
      Row() {
        Text(this.saved ? '← 返回聊天' : '专注结果')
          .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#2563EB')
          .onClick(() => {
            if (this.saved) {
              this.returnToChat();
            }
          })
        Blank()
        Text(this.saved ? '已保存' : '保存后可返回').fontSize(12).fontColor('#6B7FA0')
      }
        .width('100%').padding(20).backgroundColor('#FFFFFF')
      Scroll() {
        Column({ space: 16 }) {
          Text(this.currentSession().completionRate >= 90 ? '这一段时间，做得很扎实。' : '这次的节奏，也值得被看见。')
            .fontSize(25).fontWeight(FontWeight.Bold).fontColor('#202522').width('100%')
          Row({ space: 10 }) {
            this.StatCard(`${this.currentSession().plannedMinutes} 分钟`, '计划时长')
            this.StatCard(`${this.currentSession().actualMinutes} 分钟`, '实际专注')
            this.StatCard(`${this.currentSession().completionRate}%`, '完成度')
          }.width('100%')
          Row({ space: 10 }) { this.StatCard(`${this.currentSession().pauseCount} 次`, '暂停'); this.StatCard(`${this.currentSession().interruptionCount} 次`, '中断') }.width('100%')
          Row({ space: 10 }) { this.StatCard(this.timerLabel(), '计时方式'); this.StatCard(this.statusLabel(), '记录状态') }.width('100%')
          Column({ space: 12 }) {
            Text('这次完成得怎么样？').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#202522').width('100%')
            Row({ space: 8 }) {
              ForEach(['completed', 'partial', 'not_completed'], (value: string) => {
                Button(this.assessmentLabel(value)).layoutWeight(1).fontSize(13).fontColor(this.assessment === value ? '#FFFFFF' : '#2563EB')
                  .backgroundColor(this.assessment === value ? '#2563EB' : '#FFFFFF').borderRadius(12)
                  .border({ width: 1, color: '#BFDBFE' }).enabled(!this.saved)
                  .onClick(() => this.assessment = value as FocusSelfAssessment)
              }, (value: string) => value)
            }.width('100%')
          }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(20).border({ width: 1, color: '#F1F5F9' })
          if (this.isFixture()) {
            Column({ space: 8 }) {
              Text('离线模式的下一步建议').fontSize(14).fontWeight(FontWeight.Medium).fontColor('#2563EB').width('100%')
              Text(this.currentFeedback().feedback).fontSize(16).fontWeight(FontWeight.Medium).fontColor('#202522').lineHeight(24)
              Text(this.currentFeedback().nextSuggestion).fontSize(13).fontColor('#64748B').lineHeight(20)
            }.width('100%').padding(18).backgroundColor('#EFF6FF').borderRadius(20)
          } else {
            Text('真实模式仅保存本次 UI 专注记录，不会在前端自行更改 Agent 计划。')
              .fontSize(13).fontColor('#0F766E').lineHeight(20).width('100%').padding(16).backgroundColor('#ECFDF5').borderRadius(16)
          }
          if (this.saved) {
            Button('查看 Agent 更新后的计划').width('100%').height(52).fontColor('#FFFFFF').fontWeight(FontWeight.Bold).backgroundColor('#2563EB').borderRadius(16)
              .onClick(() => router.pushUrl({ url: 'pages/StudyPlan' }))
            Button('返回聊天页').width('100%').height(48).fontColor('#2563EB').fontWeight(FontWeight.Medium).backgroundColor('#FFFFFF')
              .border({ width: 1, color: '#BFDBFE' }).borderRadius(16)
              .onClick(() => this.returnToChat())
          } else {
            Button('保存这次记录').width('100%').height(52).fontColor('#FFFFFF').fontWeight(FontWeight.Bold).backgroundColor('#2563EB').borderRadius(16).onClick(() => this.save())
          }
        }.width('100%').padding(20)
      }.layoutWeight(1)
    }.width('100%').height('100%').backgroundColor('#FFFFFF')
    AIFloatButton()
    }.width('100%').height('100%')
  }

  private assessmentLabel(value: string): string {
    return value === 'completed' ? '完成' : value === 'partial' ? '部分完成' : '未完成';
  }

  private currentFeedback(): AgentFeedback {
    return LocalAgentService.createFocusFeedback(this.currentSession());
  }

  @Builder
  StatCard(value: string, label: string) {
    Column({ space: 4 }) { Text(value).fontSize(18).fontWeight(FontWeight.Bold).fontColor('#202522'); Text(label).fontSize(11).fontColor('#64748B') }
      .layoutWeight(1).alignItems(HorizontalAlign.Start).padding(14).backgroundColor('#F5F7FA').borderRadius(16)
  }
}
