import router from '@ohos.router';
import { appState } from '../data/AppState';
import { AgentFeedback, FocusSelfAssessment, FocusSession, FocusTask } from '../models/AgentModels';
import { LocalAgentService } from '../services/LocalAgentService';
import { AIFloatButton } from '../components/AIFloatButton';
import { ChatNavigation } from '../services/ChatNavigation';
import { AgentApiClient } from '../api/AgentApiClient';
import { DistributedStateService } from '../services/DistributedStateService';

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
      // 同 FocusTimer：必须是 ISO 8601，否则后端解析 `lastStudyAt` 失败，
      // `no_study_for_2d` 触发路径不可达。
      endedAt: draft?.endedAt ?? new Date().toISOString()
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
    const fixtureMode: boolean = this.isFixture();
    const currentPlan = appState.weeklyPlan ?? (fixtureMode ? LocalAgentService.generateWeeklyPlan(
      appState.courses, appState.homeworkDDLs, appState.currentUser
    ) : null);
    // 后端尚无专注结果写回接口，但联机计划已在本地加载。
    // 两种模式都应立即更新当前计划，否则首页完成度会一直是 0%。
    if (currentPlan !== null) {
      appState.setWeeklyPlan(LocalAgentService.adjustPlanAfterFocus(currentPlan, session));
    }
    if (fixtureMode) {
      appState.latestReview = LocalAgentService.generateReviewSummary(
        appState.latestSuggestion,
        appState.latestPartner,
        appState.latestWrongAnalysis
      );
    }
    appState.completeChatTask(
      fixtureMode ?
        (this.assessment === 'completed' ? '本次专注已完成，离线计划已同步更新。' : '本次专注结果已保存，离线计划已调整。') :
        (currentPlan !== null ? '本次专注结果已保存，当前计划进度已更新。' : '本次专注结果已保存；当前暂无可更新的计划。'),
      fixtureMode ? '查看离线模式更新后的安排。' : '查看更新后的当前计划。',
      '查看更新计划',
      'pages/StudyPlan'
    );
    this.resultSession = session;
    appState.clearFocusResultDraft();
    appState.clearFocusTask();
    // ★ 同步清除分布式共享状态。
    //   漏掉这一步会造成跨设备"僵尸任务"：本机已经结算完，另一台设备上
    //   却一直显示「手机正在专注：xxx」并提供"接着做"按钮，点了会进入一个
    //   早已结束的任务。必须与本地状态一起清理。
    DistributedStateService.getInstance().clearFocusTask();
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
            Text('真实模式会立即更新当前计划进度；待后端提供专注结果接口后再跨端同步。')
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
