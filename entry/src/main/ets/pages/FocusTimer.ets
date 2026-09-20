import router from '@ohos.router';
import { appState } from '../data/AppState';
import { FocusSession, FocusSessionStatus, FocusTask } from '../models/AgentModels';
import { AIFloatButton } from '../components/AIFloatButton';

@Entry
@Component
struct FocusTimer {
  @State remainingSeconds: number = 1800;
  @State elapsedSeconds: number = 0;
  @State paused: boolean = false;
  @State pauseCount: number = 0;
  @State interruptionCount: number = 0;
  @State showExitConfirm: boolean = false;
  @State showCompleteConfirm: boolean = false;
  private timerId: number = -1;

  aboutToAppear(): void {
    this.resetFromTask();
    this.startTimer();
  }

  aboutToDisappear(): void {
    this.stopTimer();
  }

  private resetFromTask(): void {
    const focusTask: FocusTask | null = appState.activeFocusTask;
    this.elapsedSeconds = 0;
    this.remainingSeconds = this.isStopwatch() ? 0 : (focusTask === null ? 30 : focusTask.plannedMinutes) * 60;
    this.paused = false;
    this.pauseCount = 0;
    this.interruptionCount = 0;
  }

  private startTimer(): void {
    this.stopTimer();
    this.timerId = setInterval(() => {
      if (this.paused) {
        return;
      }
      if (this.isStopwatch()) {
        this.elapsedSeconds++;
        return;
      }
      if (this.remainingSeconds > 0) {
        this.remainingSeconds--;
        this.elapsedSeconds++;
      }
      if (this.remainingSeconds <= 0) {
        this.completeSession();
      }
    }, 1000);
  }

  private stopTimer(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private isStrict(): boolean {
    return appState.activeFocusTask?.mode === 'strict';
  }

  private isStopwatch(): boolean {
    return appState.activeFocusTask?.timerType === 'stopwatch';
  }

  private displayedSeconds(): number {
    return this.isStopwatch() ? this.elapsedSeconds : this.remainingSeconds;
  }

  private displayTime(): string {
    const seconds: number = this.displayedSeconds();
    return `${Math.floor(seconds / 60).toString().padStart(2, '0')}:${(seconds % 60).toString().padStart(2, '0')}`;
  }

  private elapsedMinutes(): number {
    if (this.elapsedSeconds <= 0) {
      return 0;
    }
    return Math.max(1, Math.ceil(this.elapsedSeconds / 60));
  }

  private progressPercent(): number {
    const focusTask: FocusTask | null = appState.activeFocusTask;
    if (focusTask === null || this.isStopwatch() || focusTask.plannedMinutes <= 0) {
      return 0;
    }
    return Math.min(100, Math.round(this.elapsedSeconds / (focusTask.plannedMinutes * 60) * 100));
  }

  private completionRate(status: FocusSessionStatus): number {
    const focusTask: FocusTask | null = appState.activeFocusTask;
    if (status === 'interrupted') {
      return this.isStopwatch() ? 0 : this.progressPercent();
    }
    if (this.isStopwatch()) {
      return status === 'completed' ? 100 : 0;
    }
    if (focusTask === null || focusTask.plannedMinutes <= 0) {
      return status === 'completed' ? 100 : 0;
    }
    return Math.min(100, Math.round(this.elapsedMinutes() / focusTask.plannedMinutes * 100));
  }

  private buildSession(status: FocusSessionStatus): FocusSession {
    const focusTask: FocusTask | null = appState.activeFocusTask;
    return {
      taskId: `focus-${Date.now()}`,
      planTaskId: focusTask?.planTaskId,
      course: focusTask?.course ?? '数据结构',
      task: focusTask?.task ?? '理清二叉树中序遍历',
      plannedMinutes: this.isStopwatch() ? 0 : (focusTask?.plannedMinutes ?? 30),
      actualMinutes: this.elapsedMinutes(),
      pauseCount: this.pauseCount,
      interruptionCount: status === 'interrupted' ? this.interruptionCount + 1 : this.interruptionCount,
      completionRate: this.completionRate(status),
      selfAssessment: status === 'completed' ? 'completed' : 'not_completed',
      timerType: focusTask?.timerType ?? 'countdown',
      status: status,
      // 必须是 **ISO 8601**：这个值会作为 `lastStudyAt` 传给后端
      // `/api/v1/agent/proactive`，而后端用 `datetime.fromisoformat()` 解析。
      // 原先用 `toLocaleString()`（形如 "2026/9/20 17:30:00"）解析失败返回 None，
      // 导致 `gap_days=0`、`no_study_for_2d` 这条触发路径**永远不可达**。
      endedAt: new Date().toISOString()
    };
  }

  private openResult(status: FocusSessionStatus): void {
    this.stopTimer();
    appState.setFocusResultDraft(this.buildSession(status));
    router.pushUrl({ url: 'pages/FocusResult' });
  }

  private completeSession(): void {
    this.openResult('completed');
  }

  private togglePause(): void {
    if (this.isStrict()) {
      return;
    }
    this.paused = !this.paused;
    if (this.paused) {
      this.pauseCount++;
    }
  }

  private goBackToSetup(): void {
    if (this.isStrict()) {
      this.showExitConfirm = true;
      return;
    }
    this.showExitConfirm = true;
  }

  private showCompleteConfirmDialog(): void {
    this.showCompleteConfirm = true;
  }

  private dismissCompleteConfirm(): void {
    this.showCompleteConfirm = false;
  }

  private confirmComplete(): void {
    this.showCompleteConfirm = false;
    this.completeSession();
  }

  private showExitConfirmDialog(): void {
    this.showExitConfirm = true;
  }

  private dismissExitConfirm(): void {
    this.showExitConfirm = false;
  }

  private saveIncompleteAndLeave(): void {
    this.showExitConfirm = false;
    this.openResult('not_completed');
  }

  private leaveWithoutRecord(): void {
    this.stopTimer();
    this.showExitConfirm = false;
    const planTaskId: string | undefined = appState.activeFocusTask?.planTaskId;
    if (planTaskId !== undefined) {
      appState.updatePlanTaskStatus(planTaskId, 'todo');
    }
    router.back();
  }

  private interruptStrictFocus(): void {
    this.showExitConfirm = false;
    this.openResult('interrupted');
  }

  private statusText(): string {
    if (this.isStrict()) {
      return '严格专注进行中';
    }
    if (this.paused) {
      return '已暂停，准备好后继续';
    }
    return this.isStopwatch() ? '从现在开始，往前多走一点' : '只专注这一件事';
  }

  private modeHint(): string {
    if (this.isStrict()) {
      return '严格模式：没有暂停，提前退出会记录为中断。';
    }
    return '普通模式：可以暂停、继续，也可以提前保存未完成记录。';
  }

  build() {
    Stack() {
      Column({ space: 24 }) {
        Row() {
          Text(this.isStrict() ? '中断专注' : '← 返回设置').fontSize(14).fontColor(this.isStrict() ? '#8A3A2B' : '#2563EB').fontWeight(FontWeight.Medium)
            .onClick(() => this.goBackToSetup())
          Blank()
          Text(this.isStrict() ? '严格' : '普通').fontSize(13).fontColor(this.isStrict() ? '#FFFFFF' : '#2563EB').fontWeight(FontWeight.Bold)
            .backgroundColor(this.isStrict() ? '#1E3A5F' : '#EFF6FF').borderRadius(8).padding({ left: 10, right: 10, top: 4, bottom: 4 })
        }
        .width('100%').padding({ left: 20, right: 20, top: 12, bottom: 8 })

        Text(appState.activeFocusTask?.course ?? '数据结构')
          .fontSize(14).fontColor(this.isStrict() ? '#64748B' : '#6B7FA0').margin({ top: 16 })
        Text(appState.activeFocusTask?.task ?? '理清二叉树中序遍历')
          .fontSize(22).fontWeight(FontWeight.Bold).fontColor('#202522')
          .textAlign(TextAlign.Center).padding({ left: 28, right: 28 }).maxLines(3)

        Column({ space: 10 }) {
          Text(this.displayTime())
            .fontSize(56).fontWeight(FontWeight.Bold).fontColor(this.isStrict() ? '#1E3A5F' : '#2563EB')
          Text(this.statusText()).fontSize(14).fontColor('#64748B')
          if (!this.isStopwatch()) {
            Progress({ value: this.progressPercent(), total: 100, type: ProgressType.Ring })
              .width(28).height(28).color(this.isStrict() ? '#1E3A5F' : '#2563EB').margin({ top: 4 })
          } else {
            Text('正计时').fontSize(12).fontColor('#64748B')
          }
        }
        .alignItems(HorizontalAlign.Center).justifyContent(FlexAlign.Center)
        .width(250).height(250)
        .border({ width: 10, color: this.isStrict() ? '#D0D8F0' : (this.paused ? '#F5E6D3' : '#E8F0FE') })
        .borderRadius(125).margin({ top: 30, bottom: 20 })

        if (!this.isStrict()) {
          Button(this.paused ? '继续专注' : '暂停')
            .width('80%').height(52).fontSize(16).fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF').backgroundColor(this.paused ? '#B76B2B' : '#2563EB')
            .borderRadius(8).onClick(() => this.togglePause())
        } else {
          Text('严格模式中暂停不可用')
            .width('80%').height(44).fontSize(14).fontColor('#1E3A5F').textAlign(TextAlign.Center)
            .backgroundColor('#F0F4FF').borderRadius(8).padding({ top: 12 })
        }

        Button('完成本次专注')
          .width('80%').height(48).fontSize(15).fontColor(this.isStrict() ? '#1E3A5F' : '#2563EB')
          .backgroundColor('#FFFFFF')
          .border({ width: 1.5, color: this.isStrict() ? '#1E3A5F' : '#2563EB' }).borderRadius(8)
          .onClick(() => this.showCompleteConfirmDialog())

        Text(this.isStrict() ? '中断并结算' : '提前退出').fontSize(14).fontColor('#8A5D45')
          .margin({ top: 8 }).padding({ top: 8, bottom: 8, left: 20, right: 20 })
          .onClick(() => this.showExitConfirmDialog())

        Text(this.modeHint())
          .fontSize(11).fontColor('#7D8FA0').width('100%').textAlign(TextAlign.Center)
          .margin({ top: 4, bottom: 20 })
      }
      .width('100%').height('100%').alignItems(HorizontalAlign.Center)

      if (this.showCompleteConfirm) {
        Column() {
          Column({ space: 16 }) {
            Text('确认完成本次专注？')
              .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#202522')
            Text(`已专注 ${this.elapsedMinutes()} 分钟，确认后会进入结算页。`)
              .fontSize(14).fontColor('#64748B').lineHeight(20).textAlign(TextAlign.Center)
            Row({ space: 12 }) {
              Button('继续专注').layoutWeight(1).height(44).fontSize(14).fontWeight(FontWeight.Medium)
                .fontColor('#2563EB').backgroundColor('#FFFFFF')
                .border({ width: 1, color: '#2563EB' }).borderRadius(8)
                .onClick(() => this.dismissCompleteConfirm())
              Button('去结算').layoutWeight(1).height(44).fontSize(14).fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF').backgroundColor(this.isStrict() ? '#1E3A5F' : '#2563EB').borderRadius(8)
                .onClick(() => this.confirmComplete())
            }.width('100%')
          }
          .width('82%').padding(24).backgroundColor('#FFFFFF').borderRadius(8)
          .shadow({ radius: 20, color: '#30000000', offsetX: 0, offsetY: 8 })
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor('#40000000')
      }

      if (this.showExitConfirm) {
        Column() {
          Column({ space: 16 }) {
            Text(this.isStrict() ? '确认中断严格专注？' : '提前退出吗？')
              .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#202522')
            Text(this.isStrict() ? '这次会记录为中断，并进入结算页。' : '你可以继续，也可以保存为未完成记录。')
              .fontSize(14).fontColor('#64748B').lineHeight(20).textAlign(TextAlign.Center)
            if (this.isStrict()) {
              Row({ space: 12 }) {
                Button('继续坚持').layoutWeight(1).height(44).fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor('#FFFFFF').backgroundColor('#1E3A5F').borderRadius(8)
                  .onClick(() => this.dismissExitConfirm())
                Button('确认中断').layoutWeight(1).height(44).fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor('#8A3A2B').backgroundColor('#FFFFFF')
                  .border({ width: 1, color: '#8A3A2B' }).borderRadius(8)
                  .onClick(() => this.interruptStrictFocus())
              }.width('100%')
            } else {
              Button('继续专注').width('100%').height(42).fontSize(14).fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(8)
                .onClick(() => this.dismissExitConfirm())
              Button('保存为未完成').width('100%').height(42).fontSize(14).fontColor('#2563EB').backgroundColor('#FFFFFF')
                .border({ width: 1, color: '#2563EB' }).borderRadius(8)
                .onClick(() => this.saveIncompleteAndLeave())
              Button('不保存，返回设置').width('100%').height(42).fontSize(14).fontColor('#8A3A2B').backgroundColor('#FFFFFF')
                .border({ width: 1, color: '#D6B3A7' }).borderRadius(8)
                .onClick(() => this.leaveWithoutRecord())
            }
          }
          .width('82%').padding(24).backgroundColor('#FFFFFF').borderRadius(8)
          .shadow({ radius: 20, color: '#30000000', offsetX: 0, offsetY: 8 })
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor('#40000000')
      }
    AIFloatButton()
    }
    .width('100%').height('100%').backgroundColor(this.isStrict() ? '#F5F7FA' : '#FFFFFF')
  }
}
