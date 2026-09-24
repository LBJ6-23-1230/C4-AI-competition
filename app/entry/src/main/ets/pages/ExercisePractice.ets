import router from '@ohos.router';
import { AIFloatButton } from '../components/AIFloatButton';
import { Exercise, ExerciseAnswer, ExerciseSetResponse, ExerciseSubmissionResult } from '../api/ApiModels';
import { DemoSnapshot } from '../cache/DemoSnapshot';
import { PlanDiffCard } from '../components/PlanDiffCard';
import { FollowUpCard } from '../components/FollowUpCard';
import { ExerciseViewModel } from '../viewmodels/ExerciseViewModel';

@Entry
@Component
struct ExercisePractice {
  @State isLoading: boolean = true;
  @State isSubmitting: boolean = false;
  @State errorMessage: string = '';
  @State warningMessage: string = '';
  @State setId: string = DemoSnapshot.EXERCISE_SET_ID;
  /** 本次练哪个知识点（可由路由参数覆盖；默认是演示知识点）。 */
  @State practiceKnowledgePoint: string = DemoSnapshot.EXERCISE_KNOWLEDGE_POINT_ID;
  /** 知识点是否来自路由（= 用户从错题诊断过来的）。决定是否允许服务端现场出题。 */
  @State practiceFromRoute: boolean = false;
  @State exercises: Exercise[] = [];
  @State answers: string[] = [];
  @State result: ExerciseSubmissionResult | null = null;
  private viewModel: ExerciseViewModel = new ExerciseViewModel();
  private pageScroller: Scroller = new Scroller();
  private submissionKey: string = '';
  private requestVersion: number = 0;
  private isPageActive: boolean = false;
  private observedResetVersion: number = DemoSnapshot.getResetVersion();

  aboutToAppear(): void {
    this.isPageActive = true;
    this.readRouteParams();
    if (this.consumeDemoReset()) {
      return;
    }
    this.loadExercises();
  }

  /**
   * 允许从别的页面带一个知识点进来 —— 错题诊断完的「做同类专项题」就走这里。
   *
   * 为什么必须支持：题库有 **30 题 / 6 个知识点**，后端 `select_exercises`
   * 本来就按 `knowledgePointId` 选题。但本页原先**写死**了
   * `DemoSnapshot.EXERCISE_KNOWLEDGE_POINT_ID`，于是不管诊断出什么知识点，
   * 都只拿得到演示那 3 道题 —— 用户反馈的"一直是那三个题目"就是这个。
   *
   * ⚠️ 不带参数时仍用演示默认知识点，**演示基线（√√× → 66.67 → 42→58）不受影响**。
   */
  private readRouteParams(): void {
    try {
      const params: Record<string, Object> = router.getParams() as Record<string, Object>;
      if (params === undefined || params === null) {
        return;
      }
      const raw: Object | undefined = params['knowledgePointId'];
      if (typeof raw === 'string' && (raw as string).trim().length > 0) {
        this.practiceKnowledgePoint = (raw as string).trim();
        this.practiceFromRoute = true;
      }
    } catch (error) {
      // 直接进入本页（无路由参数）是常态，静默回落默认知识点即可。
    }
  }

  onPageShow(): void {
    this.isPageActive = true;
    this.consumeDemoReset();
  }

  onPageHide(): void {
    this.isPageActive = false;
    this.requestVersion++;
  }

  private consumeDemoReset(): boolean {
    const resetVersion: number = DemoSnapshot.getResetVersion();
    if (resetVersion !== this.observedResetVersion) {
      this.observedResetVersion = resetVersion;
      this.result = null;
      this.loadExercises(true);
      return true;
    }
    return false;
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.requestVersion++;
  }

  /**
   * 页面内重开一轮练习。
   *
   * 为什么不用 `router.pushUrl` 跳回自身：那会把 ExercisePractice 反复压进页面栈，
   * 用户按返回要退好几层。这里就地清空结果并强制重新取题，等价于"再来一组"。
   * `loadExercises(true)` 内部会重置 answers 并换一个新的 idempotencyKey，
   * 因此不会与上一轮的提交记录冲突。
   */
  private restartPractice(): void {
    this.result = null;
    this.warningMessage = '';
    this.loadExercises(true);
  }

  private async loadExercises(forceRefresh: boolean = false): Promise<void> {
    const currentRequestVersion: number = ++this.requestVersion;
    this.isLoading = true;
    this.errorMessage = '';
    this.warningMessage = '';
    const data: ExerciseSetResponse | null =
      await this.viewModel.load(DemoSnapshot.EXERCISE_SET_ID, forceRefresh, {
        knowledgePointId: this.practiceKnowledgePoint,
        count: DemoSnapshot.EXERCISE_COUNT,
        // 知识点是从别的页面带进来的（错题诊断那条路径）→ 允许题库覆盖不到时
        // 由服务端现场出题；用演示默认知识点时**不带这个参数**，演示基线不受影响。
        generate: this.practiceFromRoute
      });
    if (!this.isPageActive || currentRequestVersion !== this.requestVersion) {
      return;
    }
    if (data === null) {
      this.errorMessage = this.viewModel.getErrorMessage() || '练习题暂时加载失败，请点击重试。';
      this.isLoading = false;
      return;
    }
    this.setId = data.setId;
    this.exercises = data.exercises;
    this.answers = [];
    for (let index: number = 0; index < data.exercises.length; index++) {
      this.answers.push('');
    }
    this.submissionKey = `practice-${data.setId}-${Date.now()}`;
    this.isLoading = false;
    this.scrollToTop();
  }

  private selectAnswer(questionIndex: number, option: string): void {
    if (this.isSubmitting || this.result !== null) {
      return;
    }
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

  private practiceTitle(): string {
    if (this.exercises.length > 0 && this.exercises[0].knowledgePointName.trim().length > 0) {
      return this.exercises[0].knowledgePointName;
    }
    return '智能诊断练习';
  }

  private async submit(): Promise<void> {
    if (this.isSubmitting) {
      return;
    }
    if (this.exercises.length === 0) {
      this.errorMessage = '当前暂无可用练习题，请重试。';
      return;
    }
    if (this.answeredCount() !== this.exercises.length) {
      this.errorMessage = `请先完成全部 ${this.exercises.length} 道题，再提交。`;
      return;
    }
    const exerciseAnswers: ExerciseAnswer[] = [];
    for (let index: number = 0; index < this.exercises.length; index++) {
      exerciseAnswers.push({ exerciseId: this.exercises[index].exerciseId, answer: this.answers[index] });
    }
    this.isSubmitting = true;
    this.errorMessage = '';
    const submissionResult: ExerciseSubmissionResult | null = await this.viewModel.submit(this.setId, {
      idempotencyKey: this.submissionKey,
      answers: exerciseAnswers
    });
    if (!this.isPageActive) {
      return;
    }
    this.isSubmitting = false;
    if (submissionResult === null) {
      this.errorMessage = this.viewModel.getErrorMessage() || '提交失败，请稍后重试。';
      return;
    }
    this.warningMessage = this.viewModel.getWarningMessage();
    this.result = submissionResult;
    this.scrollToTop();
  }

  private scrollToTop(): void {
    setTimeout(() => {
      this.pageScroller.scrollEdge(Edge.Top);
    }, 100);
  }

  @Builder
  OptionButton(questionIndex: number, option: string) {
    Button(option)
      .fontSize(14).fontColor(this.isSelected(questionIndex, option) ? '#FFFFFF' : '#344054')
      .backgroundColor(this.isSelected(questionIndex, option) ? '#2563EB' : '#F8FAFC')
      .border({ width: 1, color: this.isSelected(questionIndex, option) ? '#2563EB' : '#D0D5DD' })
      .borderRadius(10).width('100%').height(42)
      .enabled(!this.isSubmitting)
      .onClick(() => this.selectAnswer(questionIndex, option))
  }

  @Builder
  QuestionCard(item: Exercise, index: number) {
    Column({ space: 12 }) {
      Text(`第 ${index + 1} 题 · ${item.knowledgePointName} · ${item.difficulty ?? '练习'}`)
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

      if (this.warningMessage.length > 0) {
        Text(this.warningMessage)
          .fontSize(13).fontColor('#B45309').lineHeight(19).width('100%')
          .padding(12).backgroundColor('#FFFBEB').borderRadius(10)
      }

      if (value.traceId !== undefined) {
        Text(`本次评估已生成可追溯记录：${value.traceId}`)
          .fontSize(12).fontColor('#0F766E').lineHeight(18).width('100%').padding(12).backgroundColor('#ECFDF5').borderRadius(10)
      }

      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(`${value.assessment.score}%`).fontSize(30).fontWeight(FontWeight.Bold).fontColor('#2563EB')
          Text('本次正确率').fontSize(12).fontColor('#667085')
        }.layoutWeight(1).alignItems(HorizontalAlign.Center).padding(14).backgroundColor('#EFF6FF').borderRadius(14)
        Column({ space: 4 }) {
          Text(`${value.assessment.oldMastery} → ${value.assessment.suggestedNewMastery}`)
            .fontSize(22).fontWeight(FontWeight.Bold).fontColor('#0F766E')
          Text(`${this.practiceTitle()}掌握度`).fontSize(12).fontColor('#667085').textAlign(TextAlign.Center)
        }.layoutWeight(1).alignItems(HorizontalAlign.Center).padding(14).backgroundColor('#ECFDF5').borderRadius(14)
      }.width('100%')

      Column({ space: 6 }) {
        Text('需要巩固').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#B45309')
        Text(value.assessment.errorTypes.length > 0 ? value.assessment.errorTypes.join('、') : '暂无明显薄弱点')
          .fontSize(14).fontColor('#475467')
      }.width('100%').padding(13).backgroundColor('#FFFBEB').borderRadius(12)

      if (value.needReplan && value.planDiff !== undefined) {
        PlanDiffCard({ value: value.planDiff })
      }

      // ★ 核心闭环收口。
      // 重构前这里只有「查看画像 / 看决策过程 / 返回首页」三个平级跳转，
      // 而**恰恰没有「再练一次」** —— 于是「练习 → 判分 → 掌握度更新 → 重规划」
      // 这条 Agent 主链在最后一格断掉了：用户看到分数变了，却不知道该干嘛。
      // 现在把「继续练这个知识点」立为唯一主行动，其余降级为次要。
      FollowUpCard({
        title: '接下来',
        reason: value.needReplan
          ? `掌握度 ${value.assessment.oldMastery} → ${value.assessment.suggestedNewMastery}，Agent 已据此重排计划。再练一轮可以继续拉高掌握度。`
          : `掌握度 ${value.assessment.oldMastery} → ${value.assessment.suggestedNewMastery}，保持这个节奏。`,
        primaryText: '再练一组同类题',
        secondaryText: '看更新后的知识画像',
        secondaryTarget: 'pages/StudyTags',
        showAgentTraceLink: true,
        onPrimary: (): void => { this.restartPractice(); }
      })

      Button('返回首页')
        .width('100%').height(44).fontSize(14).fontColor('#2563EB').backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
        .onClick(() => router.pushUrl({ url: 'pages/Index' }))
    }.width('100%')
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('← 返回').fontSize(14).fontColor('#64748B').onClick(() => router.back())
          Blank()
          Text(this.practiceTitle()).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB')
        }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 }).backgroundColor('#FFFFFF')

        Scroll(this.pageScroller) {
          Column({ space: 16 }) {
            if (this.isLoading) {
              LoadingProgress().width(36).height(36).margin({ top: 40 })
            } else if (this.result !== null) {
              this.ResultPanel(this.result)
            } else if (this.exercises.length === 0) {
              Column({ space: 14 }) {
                Text('暂无可用练习题').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#111827')
                Text(this.errorMessage || '题库可能正在更新，请稍后重试。')
                  .fontSize(14).fontColor('#667085').lineHeight(21).textAlign(TextAlign.Center)
                Button('重新加载')
                  .height(44).fontSize(15).fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(12)
                  .onClick(() => this.loadExercises(true))
              }.width('100%').margin({ top: 56 }).alignItems(HorizontalAlign.Center)
            } else {
              Text(`${this.practiceTitle()} · ${this.exercises.length} 题快速诊断`).fontSize(22).fontWeight(FontWeight.Bold).fontColor('#111827').width('100%')
              Text(`已完成 ${this.answeredCount()} / ${this.exercises.length} 题`).fontSize(13).fontColor('#667085').width('100%')
              ForEach(this.exercises, (item: Exercise, index: number) => {
                this.QuestionCard(item, index)
              }, (item: Exercise) => item.exerciseId)
              if (this.errorMessage.length > 0) {
                Text(this.errorMessage).fontSize(13).fontColor('#B45309').width('100%').padding(12).backgroundColor('#FFFBEB').borderRadius(10)
              }
              Button(this.isSubmitting ? '正在提交…' : '提交诊断')
                .width('100%').height(48).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                .backgroundColor('#2563EB').borderRadius(14)
                .enabled(!this.isSubmitting && this.answeredCount() === this.exercises.length)
                .onClick(() => this.submit())
            }
          }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 96 })
        }.layoutWeight(1).backgroundColor('#F3F6FA')
      }.width('100%').height('100%')
      AIFloatButton()
    }.width('100%').height('100%')
  }
}
