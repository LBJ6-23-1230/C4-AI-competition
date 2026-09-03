import router from '@ohos.router';
import { AIFloatButton } from '../components/AIFloatButton';
import { Exercise, ExerciseAnswer, ExerciseSetResponse, ExerciseSubmissionResult, PlanTaskChange } from '../api/ApiModels';
import { DemoSnapshot } from '../cache/DemoSnapshot';
import { ExerciseViewModel } from '../viewmodels/ExerciseViewModel';

@Entry
@Component
struct ExercisePractice {
  @State isLoading: boolean = true;
  @State isSubmitting: boolean = false;
  @State errorMessage: string = '';
  @State setId: string = DemoSnapshot.EXERCISE_SET_ID;
  @State exercises: Exercise[] = [];
  @State answers: string[] = [];
  @State result: ExerciseSubmissionResult | null = null;
  private viewModel: ExerciseViewModel = new ExerciseViewModel();

  aboutToAppear(): void {
    this.loadExercises();
  }

  private async loadExercises(): Promise<void> {
    this.isLoading = true;
    this.errorMessage = '';
    const data: ExerciseSetResponse | null = await this.viewModel.load(DemoSnapshot.EXERCISE_SET_ID);
    if (data === null) {
      this.errorMessage = '练习题暂时加载失败，请点击重试。';
      this.isLoading = false;
      return;
    }
    this.setId = data.setId;
    this.exercises = data.exercises;
    this.answers = [];
    for (let index: number = 0; index < data.exercises.length; index++) {
      this.answers.push('');
    }
    this.isLoading = false;
  }

  private selectAnswer(questionIndex: number, option: string): void {
    const nextAnswers: string[] = this.answers.slice();
    nextAnswers[questionIndex] = option.substring(0, 1);
    this.answers = nextAnswers;
  }

  private answeredCount(): number {
    let count: number = 0;
    for (let index: number = 0; index < this.answers.length; index++) {
      if (this.answers[index].length > 0) {
        count++;
      }
    }
    return count;
  }

  private isSelected(questionIndex: number, option: string): boolean {
    return this.answers[questionIndex] === option.substring(0, 1);
  }

  private async submit(): Promise<void> {
    if (this.answeredCount() !== this.exercises.length) {
      this.errorMessage = '请先完成全部 3 道题，再提交。';
      return;
    }
    const exerciseAnswers: ExerciseAnswer[] = [];
    for (let index: number = 0; index < this.exercises.length; index++) {
      exerciseAnswers.push({ exerciseId: this.exercises[index].exerciseId, answer: this.answers[index] });
    }
    this.isSubmitting = true;
    this.errorMessage = '';
    const submissionResult: ExerciseSubmissionResult | null = await this.viewModel.submit(this.setId, {
      idempotencyKey: `demo-${Date.now()}`,
      answers: exerciseAnswers
    });
    this.isSubmitting = false;
    if (submissionResult === null) {
      this.errorMessage = '提交失败，请稍后重试。';
      return;
    }
    this.result = submissionResult;
  }

  @Builder
  OptionButton(questionIndex: number, option: string) {
    Button(option)
      .fontSize(14).fontColor(this.isSelected(questionIndex, option) ? '#FFFFFF' : '#344054')
      .backgroundColor(this.isSelected(questionIndex, option) ? '#2563EB' : '#F8FAFC')
      .border({ width: 1, color: this.isSelected(questionIndex, option) ? '#2563EB' : '#D0D5DD' })
      .borderRadius(10).width('100%').height(42)
      .onClick(() => this.selectAnswer(questionIndex, option))
  }

  @Builder
  QuestionCard(item: Exercise, index: number) {
    Column({ space: 12 }) {
      Text(`第 ${index + 1} 题 · ${item.difficulty ?? '练习'}`)
        .fontSize(12).fontColor('#2563EB').fontWeight(FontWeight.Bold)
      Text(item.stem).fontSize(16).fontColor('#1F2937').fontWeight(FontWeight.Medium).lineHeight(23)
      ForEach(item.options, (option: string) => {
        this.OptionButton(index, option)
      }, (option: string) => option)
    }
    .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
    .border({ width: 1, color: '#E2E8F0' })
  }

  @Builder
  ResultPanel(value: ExerciseSubmissionResult) {
    Column({ space: 16 }) {
      Text('诊断结果已生成').fontSize(23).fontWeight(FontWeight.Bold).fontColor('#111827').width('100%')
      Text('评分、掌握度和重规划结果均来自接口返回，前端只负责展示。')
        .fontSize(13).fontColor('#667085').lineHeight(19).width('100%')

      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(`${value.assessment.score}%`).fontSize(30).fontWeight(FontWeight.Bold).fontColor('#2563EB')
          Text('本次正确率').fontSize(12).fontColor('#667085')
        }.layoutWeight(1).alignItems(HorizontalAlign.Center).padding(14).backgroundColor('#EFF6FF').borderRadius(14)
        Column({ space: 4 }) {
          Text(`${value.assessment.oldMastery} → ${value.assessment.suggestedNewMastery}`)
            .fontSize(22).fontWeight(FontWeight.Bold).fontColor('#0F766E')
          Text('二叉树后序遍历掌握度').fontSize(12).fontColor('#667085').textAlign(TextAlign.Center)
        }.layoutWeight(1).alignItems(HorizontalAlign.Center).padding(14).backgroundColor('#ECFDF5').borderRadius(14)
      }.width('100%')

      Column({ space: 6 }) {
        Text('需要巩固').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#B45309')
        Text(value.assessment.errorTypes.join('、')).fontSize(14).fontColor('#475467')
      }.width('100%').padding(13).backgroundColor('#FFFBEB').borderRadius(12)

      if (value.needReplan && value.planDiff !== undefined) {
        Column({ space: 9 }) {
          Text(`Plan V${value.planDiff.newVersion} 已自动生成`).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#111827')
          Text(value.planDiff.adjustmentReason).fontSize(13).fontColor('#475467').lineHeight(19)
          ForEach(value.planDiff.changedTasks, (change: PlanTaskChange) => {
            Text(`${change.taskId}：${change.change ?? '已调整'} · ${change.durationMinutes ?? 0} 分钟`)
              .fontSize(13).fontColor('#1F2937').width('100%').padding(10).backgroundColor('#F8FAFC').borderRadius(9)
          }, (change: PlanTaskChange) => change.taskId)
        }.width('100%').padding(14).backgroundColor('#FFFFFF').border({ width: 1, color: '#BFDBFE' }).borderRadius(14)
      }

      Button('查看更新后的知识画像')
        .width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        .backgroundColor('#2563EB').borderRadius(12).onClick(() => router.pushUrl({ url: 'pages/StudyTags' }))
      Button('查看 Agent 决策过程')
        .width('100%').height(44).fontSize(14).fontColor('#2563EB').backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#BFDBFE' }).borderRadius(12).onClick(() => router.pushUrl({ url: 'pages/AgentTrace' }))
      Button('返回首页')
        .width('100%').height(44).fontSize(14).fontColor('#2563EB').backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#BFDBFE' }).borderRadius(12).onClick(() => router.pushUrl({ url: 'pages/Index' }))
    }.width('100%')
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('← 返回').fontSize(14).fontColor('#64748B').onClick(() => router.back())
          Blank()
          Text('二叉树诊断练习').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB')
        }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 }).backgroundColor('#FFFFFF')

        Scroll() {
          Column({ space: 16 }) {
            if (this.isLoading) {
              LoadingProgress().width(36).height(36).margin({ top: 40 })
            } else if (this.result !== null) {
              this.ResultPanel(this.result)
            } else {
              Text('二叉树后序遍历 · 3 题快速诊断').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#111827').width('100%')
              Text(`已完成 ${this.answeredCount()} / ${this.exercises.length} 题`).fontSize(13).fontColor('#667085').width('100%')
              ForEach(this.exercises, (item: Exercise, index: number) => {
                this.QuestionCard(item, index)
              }, (item: Exercise) => item.exerciseId)
              if (this.errorMessage.length > 0) {
                Text(this.errorMessage).fontSize(13).fontColor('#B45309').width('100%').padding(12).backgroundColor('#FFFBEB').borderRadius(10)
              }
              Button(this.isSubmitting ? '正在提交…' : '提交诊断')
                .width('100%').height(48).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                .backgroundColor('#2563EB').borderRadius(14).enabled(!this.isSubmitting)
                .onClick(() => this.submit())
            }
          }.width('100%').padding(16)
        }.layoutWeight(1).backgroundColor('#F3F6FA')
      }.width('100%').height('100%')
      AIFloatButton()
    }.width('100%').height('100%')
  }
}
