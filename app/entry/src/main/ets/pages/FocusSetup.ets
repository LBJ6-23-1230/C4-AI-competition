import router from '@ohos.router';
import { appState } from '../data/AppState';
import { FocusMode, FocusSource, FocusTask, FocusTimerType } from '../models/AgentModels';
import { AIFloatButton } from '../components/AIFloatButton';

@Entry
@Component
struct FocusSetup {
  @State course: string = '数据结构';
  @State task: string = '理清二叉树中序遍历';
  @State minutes: number = 30;
  @State customMinutesText: string = '45';
  @State selectedDuration: string = '30';
  @State mode: FocusMode = 'normal';
  @State source: FocusSource = 'manual';
  @State timerType: FocusTimerType = 'countdown';

  aboutToAppear(): void {
    const imported: FocusTask | null = appState.activeFocusTask;
    if (imported !== null) {
      this.course = imported.course;
      this.task = imported.task;
      this.minutes = imported.plannedMinutes > 0 ? imported.plannedMinutes : 30;
      this.mode = imported.mode;
      this.source = imported.source;
      this.timerType = imported.timerType ?? 'countdown';
      this.selectedDuration = imported.timerType === 'stopwatch' ? 'stopwatch' : this.durationKey(this.minutes);
      this.customMinutesText = this.selectedDuration === 'custom' ? this.minutes.toString() : this.customMinutesText;
    } else if (appState.courses.length > 0) {
      this.course = appState.getHighPriorityCourse().courseName;
    }
  }

  private durationKey(value: number): string {
    if (value === 30) {
      return '30';
    }
    if (value === 60) {
      return '60';
    }
    return 'custom';
  }

  private selectCountdown(value: number): void {
    this.timerType = 'countdown';
    this.minutes = value;
    this.selectedDuration = value.toString();
  }

  private selectCustom(): void {
    this.timerType = 'countdown';
    this.selectedDuration = 'custom';
    this.minutes = this.normalizedCustomMinutes();
  }

  private selectStopwatch(): void {
    this.timerType = 'stopwatch';
    this.selectedDuration = 'stopwatch';
  }

  private normalizedCustomMinutes(): number {
    const raw: number = Number(this.customMinutesText.replace(/[^0-9]/g, ''));
    if (raw < 1) {
      return 1;
    }
    if (raw > 180) {
      return 180;
    }
    return raw;
  }

  private onCustomMinutesChange(value: string): void {
    this.customMinutesText = value;
    if (this.selectedDuration === 'custom') {
      this.minutes = this.normalizedCustomMinutes();
    }
  }

  private plannedMinutesForStart(): number {
    if (this.timerType === 'stopwatch') {
      return 0;
    }
    if (this.selectedDuration === 'custom') {
      return this.normalizedCustomMinutes();
    }
    return this.minutes;
  }

  private startFocus(): void {
    const planTaskId: string | undefined = appState.activeFocusTask?.planTaskId;
    appState.setFocusTask({
      course: this.course,
      task: this.task.trim(),
      plannedMinutes: this.plannedMinutesForStart(),
      source: this.source,
      mode: this.mode,
      timerType: this.timerType,
      planTaskId: planTaskId
    });
    if (planTaskId !== undefined) {
      appState.updatePlanTaskStatus(planTaskId, 'in_progress');
    }
    appState.clearFocusResultDraft();
    router.pushUrl({ url: 'pages/FocusTimer' });
  }

  private getSourceLabel(): string {
    switch (this.source) {
      case 'agent': return '来自 Agent 学习计划';
      case 'course': return '来自课程任务';
      case 'collaborative': return '来自协同学习';
      default: return '自己安排';
    }
  }

  private modeHint(): string {
    if (this.mode === 'strict') {
      return '严格专注会隐藏暂停；提前退出需要确认，并留下中断记录。';
    }
    return '普通专注可以暂停、继续，也可以把未完成的记录保存下来。';
  }

  private timerHint(): string {
    if (this.timerType === 'stopwatch') {
      return '正计时不设目标，从 00:00 开始，结束时按实际投入结算。';
    }
    return `本次目标 ${this.plannedMinutesForStart()} 分钟。`;
  }

  build() {
    Stack() {
    Column() {
      Row() {
        Text('← 返回首页').fontSize(14).fontColor('#2563EB').fontWeight(FontWeight.Medium)
          .onClick(() => router.pushUrl({ url: 'pages/Index' }))
        Blank()
        Text('专注设置').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#2563EB')
          .backgroundColor('#EFF6FF').borderRadius(8).padding({ left: 10, right: 10, top: 4, bottom: 4 })
      }.width('100%').padding(20).backgroundColor('#FFFFFF')

      Scroll() {
        Column({ space: 18 }) {
          Text('现在，就做这一件事')
            .fontSize(26).fontWeight(FontWeight.Bold).fontColor('#202522').width('100%')
          Text('把任务说清楚，再给自己一段不被打扰的时间。')
            .fontSize(14).fontColor('#64748B').width('100%')

          Text(this.getSourceLabel()).fontSize(12).fontColor('#2563EB')
            .backgroundColor('#EFF6FF').borderRadius(8).padding({ left: 10, right: 10, top: 3, bottom: 3 })

          Column({ space: 10 }) {
            Text('课程').fontSize(13).fontColor('#64748B').width('100%')
            Row({ space: 6 }) {
              Text(this.course).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#202522')
                .layoutWeight(1).padding(16).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#F1F5F9' })
              if (appState.courses.length > 1) {
                Text('切换').fontSize(13).fontColor('#2563EB').padding(10)
                  .onClick(() => {
                    let currentIdx: number = appState.courses.findIndex(c => c.courseName === this.course);
                    let nextIdx: number = (currentIdx + 1) % appState.courses.length;
                    this.course = appState.courses[nextIdx].courseName;
                  })
              }
            }.width('100%')

            Text('任务').fontSize(13).fontColor('#64748B').margin({ top: 8 }).width('100%')
            TextInput({ text: this.task, placeholder: '例如：完成二叉树遍历练习' })
              .fontSize(16).fontColor('#202522').backgroundColor('#FFFFFF').borderRadius(8).padding(16)
              .onChange((value: string) => this.task = value)
          }.width('100%').padding(18).backgroundColor('#F5F7FA').borderRadius(8)

          Column({ space: 12 }) {
            Text('计时方式').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#202522').width('100%')
            Row({ space: 8 }) {
              this.DurationButton('30 分钟', '30')
              this.DurationButton('60 分钟', '60')
            }.width('100%')
            Row({ space: 8 }) {
              this.DurationButton('自定义', 'custom')
              this.DurationButton('正计时', 'stopwatch')
            }.width('100%')

            if (this.selectedDuration === 'custom') {
              TextInput({ text: this.customMinutesText, placeholder: '1-180 分钟' })
                .type(InputType.Number).fontSize(15).fontColor('#202522')
                .backgroundColor('#F5F7FA').borderRadius(8).padding(12)
                .onChange((value: string) => this.onCustomMinutesChange(value))
            }
            Text(this.timerHint()).fontSize(12).fontColor('#64748B').width('100%')
          }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#F1F5F9' })

          Column({ space: 12 }) {
            Text('专注方式').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#202522').width('100%')
            Row({ space: 10 }) {
              Button('普通专注').layoutWeight(1).fontColor(this.mode === 'normal' ? '#FFFFFF' : '#2563EB')
                .backgroundColor(this.mode === 'normal' ? '#2563EB' : '#FFFFFF').borderRadius(8)
                .border({ width: 1, color: '#BFDBFE' }).onClick(() => this.mode = 'normal')
              Button('严格专注').layoutWeight(1).fontColor(this.mode === 'strict' ? '#FFFFFF' : '#1E3A5F')
                .backgroundColor(this.mode === 'strict' ? '#1E3A5F' : '#FFFFFF').borderRadius(8)
                .border({ width: 1, color: '#93A3C0' }).onClick(() => this.mode = 'strict')
            }.width('100%')
            Text(this.modeHint()).fontSize(12).fontColor('#64748B').width('100%')
          }.width('100%').padding(18).backgroundColor(this.mode === 'strict' ? '#F0F4FF' : '#FFFFFF')
            .borderRadius(8).border({ width: 1, color: this.mode === 'strict' ? '#94A3B8' : '#F1F5F9' })

          if (!appState.isDataImported && appState.courses.length <= 3) {
            Text('导入真实课表后，这里的建议会更贴近你的时间和作业。')
              .fontSize(11).fontColor('#7D8FA0').width('100%')
              .onClick(() => router.pushUrl({ url: 'pages/CourseImport' }))
          }

          Button('开始专注')
            .width('100%').height(52).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            .backgroundColor(this.mode === 'strict' ? '#1E3A5F' : '#2563EB').borderRadius(8)
            .enabled(this.task.trim().length > 0)
            .onClick(() => this.startFocus())
        }.width('100%').padding(20)
      }.layoutWeight(1)
    }.width('100%').height('100%').backgroundColor('#FFFFFF')
    AIFloatButton()
    }.width('100%').height('100%')
  }

  @Builder
  DurationButton(label: string, key: string) {
    Button(label).layoutWeight(1).height(42).fontSize(13)
      .fontColor(this.selectedDuration === key ? '#FFFFFF' : '#2563EB')
      .backgroundColor(this.selectedDuration === key ? '#2563EB' : '#FFFFFF')
      .borderRadius(8).border({ width: 1, color: '#BFDBFE' })
      .onClick(() => {
        if (key === '30') {
          this.selectCountdown(30);
        } else if (key === '60') {
          this.selectCountdown(60);
        } else if (key === 'custom') {
          this.selectCustom();
        } else {
          this.selectStopwatch();
        }
      })
  }
}
