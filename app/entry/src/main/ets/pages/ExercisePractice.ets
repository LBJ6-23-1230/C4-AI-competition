import router from '@ohos.router';
import { AIFloatButton } from '../components/AIFloatButton';
import { Exercise, ExerciseAnswer, ExerciseSetResponse, ExerciseSubmissionResult, KnowledgeMastery } from '../api/ApiModels';
import { DemoSnapshot } from '../cache/DemoSnapshot';
import { PlanDiffCard } from '../components/PlanDiffCard';
import { FollowUpCard } from '../components/FollowUpCard';
import { ExerciseViewModel } from '../viewmodels/ExerciseViewModel';
import { ProfileViewModel, ProfileViewState } from '../viewmodels/ProfileViewModel';
import { appState } from '../data/AppState';

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
  /** 知识点是否由**调用方显式指定**（路由参数，或用户在选择器里点选）。决定是否允许服务端现场出题。 */
  @State practiceFromRoute: boolean = false;
  @State exercises: Exercise[] = [];
  @State answers: string[] = [];
  @State result: ExerciseSubmissionResult | null = null;
  /**
   * 知识点选择器。
   *
   * 为什么要有：本页此前只有"路由带参数"与"回落到写死的演示知识点"两种情况，
   * 而三个入口（知识画像的「按薄弱点开始专项练习」、我的智能体的「练习智能体」、
   * 知识画像的「启动 Agent 诊断会话」）**都不带参数** —— 于是不管画像上最薄弱的是
   * 哪个知识点，用户拿到的永远是二叉树那三道题。现在没带参数就先让用户自己选。
   */
  @State showPicker: boolean = false;
  @State pickerLoading: boolean = false;
  @State pickerErrorMessage: string = '';
  @State pickerOptions: KnowledgeMastery[] = [];
  private profileViewModel: ProfileViewModel = new ProfileViewModel();
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
    this.startFlow();
  }

  /**
   * 进页分流：调用方带了知识点就直接练；没带就先让用户自己选。
   *
   * 修的是什么：三个入口（知识画像的「按薄弱点开始专项练习」、我的智能体的
   * 「练习智能体」、知识画像的「启动 Agent 诊断会话」）**都不带参数**，
   * 本页因此回落到写死的 `binary-tree-postorder` —— 于是画像上最薄弱的
   * 明明是别的知识点，用户拿到的却永远是二叉树那三道题。
   */
  private startFlow(): void {
    if (this.practiceFromRoute) {
      this.loadExercises();
      return;
    }
    this.loadPickerOptions();
  }

  /**
   * 读当前身份的知识点，按掌握度**升序**排列 —— 最薄弱的排最前。
   *
   * 分数与排序依据全部来自 `/api/v1/profile`，前端只做展示与排序，
   * 不重新计算掌握度（与项目纪律一致）。
   */
  private async loadPickerOptions(): Promise<void> {
    this.pickerLoading = true;
    this.pickerErrorMessage = '';
    const id: string = appState.currentUser.userId;
    const state: ProfileViewState =
      await this.profileViewModel.load(id.length > 0 ? id : DemoSnapshot.USER_ID, true);
    if (!this.isPageActive) {
      return;
    }
    this.pickerLoading = false;
    this.pickerErrorMessage = state.errorMessage;
    const sorted: KnowledgeMastery[] = state.mastery.slice();
    sorted.sort((left: KnowledgeMastery, right: KnowledgeMastery): number =>
      left.masteryScore - right.masteryScore);
    this.pickerOptions = sorted;
    this.showPicker = true;
  }

  /** 选定知识点后开练。知识点由用户显式指定 → 允许题库覆盖不到时由服务端现场出题。 */
  private chooseKnowledgePoint(point: KnowledgeMastery): void {
    this.practiceKnowledgePoint = point.knowledgePointId;
    this.practiceFromRoute = true;
    this.showPicker = false;
    this.result = null;
    this.loadExercises(true);
  }

  /**
   * 画像里还没有任何知识点时的兜底：用演示知识点练一轮。
   * 如实标注是演示题目，不假装成"针对你的薄弱点出的题"。
   */
  private practiceDemoPoint(): void {
    this.practiceKnowledgePoint = DemoSnapshot.EXERCISE_KNOWLEDGE_POINT_ID;
    this.practiceFromRoute = false;
    this.showPicker = false;
    this.result = null;
    this.loadExercises(true);
  }

  /** 从练习界面回到选择器，换一个知识点练。 */
  private backToPicker(): void {
    this.result = null;
    this.loadPickerOptions();
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
        // “再练一组”必须排除当前屏幕上的题。此前 forceRefresh 只绕过前端缓存，
        // 后端仍从题库第 1 题开始取，因此每次都会拿回完全相同的三题。
        excludeExerciseIds: forceRefresh
          ? this.exercises.map((item: Exercise): string => item.exerciseId) : [],
        // 知识点是从别的页面带进来的（错题诊断那条路径）→ 允许题库覆盖不到时
        // 由服务端现场出题；用演示默认知识点时**不带这个参数**，演示基线不受影响。
        generate: this.practiceFromRoute
      });
    if (!this.isPageActive || currentRequestVersion !== this.requestVersion) {
      return;
    }
    // ⚠️ 用户**主动要一组新题**（forceRefresh）却没拿到新题时，必须清空上一轮的题与作答。
    // 两条路径都会落到这里：
    //   1. `data === null` —— 请求彻底失败；
    //   2. 请求失败、但 `ExerciseViewModel` 用缓存兜了底（它会把 errorMessage 写上）。
    // 不清的话屏幕上仍是上一轮的题目、选项还带着上次的选择 —— 用户会以为
    // 这就是新出的题（实测反馈："第三次加载十几秒后依旧是第二次的题目和做题结果"）。
    const loadError: string = this.viewModel.getErrorMessage();
    if (data === null || (forceRefresh && loadError.length > 0)) {
      this.exercises = [];
      this.answers = [];
      this.errorMessage = loadError || '练习题暂时加载失败，请点击重试。';
      this.isLoading = false;
      return;
    }
    if (data.exercises.length === 0) {
      // 后端在"点名了题库覆盖不到的知识点、且现场出题失败"时会如实返回空列表
      // （见 app/api/exercises.py 的 generationFailed 分支）——这里明确告诉用户，
      // 而不是把上一轮的题留在屏幕上假装成功。
      this.exercises = [];
      this.answers = [];
      this.errorMessage = '这次没能为所选知识点拿到题目（现场出题失败或题库已练完），请点「重新加载」再试一次。';
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

      // 反馈之后的三条路：继续练同一个知识点 / 去画像看新的掌握度 / 换一个知识点。
      // 这正是用户要的"根据反馈结果决定继续练还是刷新画像"——两个都给，由用户点。
      Button('换一个知识点练')
        .width('100%').height(44).fontSize(14).fontColor('#2563EB').backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
        .onClick(() => this.backToPicker())

      Button('返回首页')
        .width('100%').height(44).fontSize(14).fontColor('#2563EB').backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
        .onClick(() => router.pushUrl({ url: 'pages/Index' }))
    }.width('100%')
  }

  /**
   * 知识点选择器 —— 进入本页的默认第一步。
   *
   * 用户在三个入口点「开始练习」时都还没有指定练什么，此前页面直接替他决定了
   * （写死的演示知识点）。这里把选择权交回用户：按掌握度升序排，最薄弱的排最前，
   * 但**不强制** —— 想练哪个由用户点。
   */
  @Builder
  KnowledgePointPicker() {
    Column({ space: 14 }) {
      Text('选择要练的知识点').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#111827').width('100%')
      Text('按掌握度从低到高排列，最薄弱的排在最前。分数来自你的知识画像，不由前端计算。')
        .fontSize(13).fontColor('#667085').lineHeight(19).width('100%')

      if (this.pickerErrorMessage.length > 0) {
        Text(this.pickerErrorMessage)
          .fontSize(13).fontColor('#B45309').lineHeight(19).width('100%')
          .padding(12).backgroundColor('#FFFBEB').borderRadius(10)
      }

      if (this.pickerOptions.length === 0) {
        Column({ space: 12 }) {
          Text('还没有可练的知识点').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#111827').width('100%')
          Text('你的知识画像里目前没有知识点记录。可以先做一轮演示题目 —— 做完会按**实际答题结果**建立掌握度，之后这里就会列出你自己的知识点。')
            .fontSize(13).fontColor('#667085').lineHeight(20).width('100%')
          Button('先用演示知识点练一轮')
            .width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            .backgroundColor('#2563EB').borderRadius(12)
            .onClick(() => this.practiceDemoPoint())
        }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
      } else {
        ForEach(this.pickerOptions, (item: KnowledgeMastery, index: number) => {
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              Text(item.knowledgePointName)
                .fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1F2937').layoutWeight(1)
              if (index === 0) {
                Text('最薄弱').fontSize(11).fontColor('#B45309').backgroundColor('#FEF3C7')
                  .borderRadius(8).padding({ left: 8, right: 8, top: 3, bottom: 3 })
              }
              Text(`${item.masteryScore}`).fontSize(20).fontWeight(FontWeight.Bold).fontColor('#2563EB')
              Text(' / 100').fontSize(11).fontColor('#64748B').margin({ top: 6 })
            }.width('100%').alignItems(VerticalAlign.Top)
            Progress({ value: item.masteryScore, total: 100, type: ProgressType.Linear })
              .color('#2563EB').backgroundColor('#DBEAFE').height(8).borderRadius(8)
            Text('开始专项练习 →').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#2563EB')
          }
          .width('100%').padding(14).backgroundColor('#FFFFFF').borderRadius(14)
          .border({ width: 1, color: index === 0 ? '#BFDBFE' : '#E2E8F0' })
          .onClick(() => this.chooseKnowledgePoint(item))
        }, (item: KnowledgeMastery) => item.knowledgePointId)
      }
    }.width('100%')
  }

  build() {
    Stack() {
      Column() {
        Row({ space: 12 }) {
          Text('← 返回').fontSize(14).fontColor('#64748B').onClick(() => router.back())
          Blank()
          if (!this.showPicker && !this.pickerLoading) {
            Text('换知识点').fontSize(13).fontColor('#2563EB')
              .onClick(() => this.backToPicker())
          }
          Text(this.showPicker || this.pickerLoading ? '选择知识点' : this.practiceTitle())
            .fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB')
        }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 }).backgroundColor('#FFFFFF')

        Scroll(this.pageScroller) {
          Column({ space: 16 }) {
            if (this.pickerLoading) {
              Column({ space: 10 }) {
                LoadingProgress().width(32).height(32)
                Text('正在读取你的知识点…').fontSize(14).fontColor('#64748B')
              }
              .width('100%').padding(32).alignItems(HorizontalAlign.Center)
            } else if (this.showPicker) {
              this.KnowledgePointPicker()
            } else if (this.isLoading) {
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
