import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { appState } from '../data/AppState';
import { WrongAnalysisResult } from '../models/AgentModels';
import { FollowUpCard } from '../components/FollowUpCard';
import { LocalAgentService } from '../services/LocalAgentService';
import { ChatNavigation } from '../services/ChatNavigation';
import { AIFloatButton } from '../components/AIFloatButton';
import { AgentApiClient } from '../api/AgentApiClient';
import { AgentBridge } from '../services/AgentBridge';
import { AgentResponse, WrongAnalysis } from '../models/ChatModels';
import { ImageEncoder } from '../utils/ImageEncoder';

@Entry
@Component
struct WrongQuestion {
  @State hasPhoto: boolean = false;
  @State selectedImageUri: string = '';
  //: 当前这张图是不是「内置示例错题」。
  //:
  //: 内置图来自**应用资源**（`$r('app.media.sample_wrong')`），没有可供 `Image()`
  //: 使用的文件 URI —— 原实现把 `selectedImageUri` 留成空串，于是预览区
  //: 既不满足 `startsWith('mock_')`、`Image('')` 又是空图，**页面上根本没有题目照片**
  //: （实测反馈：「点击这个用内置示例错题体验根本没有题目照片」）。
  //: 现在用这个标记显式区分「内置示例 / 模拟图 / 相册图」三种来源。
  @State isSampleImage: boolean = false;
  @State selectedImageName: string = '';
  @State isAnalyzing: boolean = false;
  @State analysisResult: WrongAnalysisResult | null = null;
  @State showAnalysis: boolean = false;
  @State reviewAdded: boolean = false;
  @State analysisMessage: string = '';
  private analysisRequestVersion: number = 0;
  private isPageActive: boolean = false;

  aboutToAppear(): void {
    this.isPageActive = true;
    if (appState.selectedImageUri.length > 0) {
      this.selectedImageUri = appState.selectedImageUri;
      this.hasPhoto = true;
      const latestImage = appState.getLatestImage();
      if (latestImage !== null) {
        this.selectedImageName = latestImage.fileName;
      }
    }
    if (appState.latestWrongAnalysis !== null) {
      this.analysisResult = appState.latestWrongAnalysis;
      this.showAnalysis = true;
      // reviewAdded 只表示"本次真的新增了"（见 addToTomorrowPlan）：
      // 重开页面时即使该知识点早已在复习计划里，也不置为 true，
      // 否则按钮会说成"刚刚加入"；这种情况由 reviewButtonText() 依计划状态
      // 显示「已在明日复习计划中」，与 handoff 文案同一口径。
      this.reviewAdded = false;
    }
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.analysisRequestVersion++;
  }

  private goBack(): void {
    appState.leaveChatTask();
    ChatNavigation.returnToChat();
  }

  private async pickFromGallery(): Promise<void> {
    try {
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const result = await photoPicker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      });
      if (result.photoUris.length > 0) {
        const uri: string = result.photoUris[0];
        this.selectedImageUri = uri;
        this.isSampleImage = false;
        this.selectedImageName = `photo_${Date.now()}.jpg`;
        this.hasPhoto = true;
        appState.addWrongQuestionImage(uri, this.selectedImageName);
        this.startAnalysis(uri);
      }
    } catch (error) {
      console.error(`选图失败: ${JSON.stringify(error)}`);
      if (this.isFixture()) this.useMockImage();
      else this.analysisMessage = '无法读取图片，请检查媒体权限后重试。';
    }
  }

  /**
   * 「快速体验」入口：在线与离线各走各的链路。
   *
   * * 离线（Fixture）→ 本地预置分析（原行为，演示基线不受影响）；
   * * 在线（真实后端）→ **内置示例图 + 真实 Qwen-VL 识别**。
   *   这不是 Mock：图是真的、模型是真的、返回的结构化知识点也是真的，
   *   只是图片来自内置资源而不是相册（相册常为空，见方法内注释）。
   */
  private useSampleImage(): void {
    if (this.isFixture()) {
      this.useMockImage();
      return;
    }
    void this.startOnlineAnalysisFromSample();
  }

  private useMockImage(): void {
    const mockUri: string = `mock_${Date.now()}.jpg`;
    this.selectedImageUri = mockUri;
    this.isSampleImage = false;
    this.selectedImageName = '模拟错题图片.jpg';
    this.hasPhoto = true;
    appState.addWrongQuestionImage(mockUri, this.selectedImageName);
    this.startAnalysis(mockUri);
  }

  private isFixture(): boolean {
    return AgentApiClient.getConfig().useFixture;
  }

  private startAnalysis(imageUri: string): void {
    if (!this.isFixture()) {
      // 在线：走**真实多模态识别**（Qwen-VL），不再拒绝。
      void this.startOnlineAnalysis(imageUri);
      return;
    }
    const requestVersion: number = ++this.analysisRequestVersion;
    this.isAnalyzing = true;
    this.showAnalysis = false;
    this.analysisResult = null;
    this.reviewAdded = false;
    this.analysisMessage = '';
    appState.latestWrongAnalysis = null;
    setTimeout(() => {
      if (!this.isPageActive || requestVersion !== this.analysisRequestVersion) {
        return;
      }
      const result: WrongAnalysisResult = LocalAgentService.analyzeWrongQuestion(imageUri);
      this.analysisResult = result;
      this.showAnalysis = true;
      this.isAnalyzing = false;
      appState.latestWrongAnalysis = result;
    }, 1200);
  }

  /**
   * 在线（真实后端）错题分析 —— 图片交给 Qwen-VL，并**接回结构化知识点**。
   *
   * ## 修复的缺陷
   *
   * 原实现在这里直接 `return`，只留一句「真实模式已禁用前端预置分析」——
   * 也就是**账号登录后点完图片什么都不做**，而离线反而能跑完整流程。
   * 这正是"游客能、账号用不了"最典型的一处。
   *
   * 之所以当初要禁用：那张分析卡片依赖的是本地 mock 结构，而在线没有对应实现。
   * 现在补上了：后端 `_handle_analyze_wrong` 的图片分支会返回
   * `{reply, knowledgePoint, wrongType}`，`AgentBridge` 解析成 `wrongAnalysis`。
   * 于是「做同类专项题」能带着**这道题真正考的知识点**去请求题集 ——
   * 题库命中就用题库，没命中由后端现场出题，最后仍是确定性判分。
   */
  private async startOnlineAnalysis(imageUri: string): Promise<void> {
    const requestVersion: number = ++this.analysisRequestVersion;
    this.isAnalyzing = true;
    this.showAnalysis = false;
    this.analysisResult = null;
    this.reviewAdded = false;
    this.analysisMessage = '';
    appState.latestWrongAnalysis = null;

    const encoded: string = await ImageEncoder.toBase64(imageUri);
    if (!this.isPageActive || requestVersion !== this.analysisRequestVersion) {
      return;
    }
    if (encoded.length === 0) {
      this.isAnalyzing = false;
      this.analysisMessage = ImageEncoder.describeFailure();
      return;
    }
    await this.runOnlineAnalysis(encoded, imageUri);
  }

  /**
   * 用**内置示例错题图**走一遍在线诊断。
   *
   * 为什么要它：演示链路依赖相册里有图，而模拟器与新设备的相册通常是空的 ——
   * 评委现场拿不到图就演示不了。内置一张示例图，点一下走的是
   * **完全相同的真实识别链路**（图 → base64 → Qwen-VL → 结构化知识点），
   * 只是图从相册换成了内置资源。界面文案必须标明是"内置示例"。
   */
  private async startOnlineAnalysisFromSample(): Promise<void> {
    const requestVersion: number = ++this.analysisRequestVersion;
    this.isAnalyzing = true;
    this.showAnalysis = false;
    this.analysisResult = null;
    this.reviewAdded = false;
    this.analysisMessage = '';
    appState.latestWrongAnalysis = null;

    const context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    const encoded: string = ImageEncoder.fromResource(context, $r('app.media.sample_wrong').id);
    if (!this.isPageActive || requestVersion !== this.analysisRequestVersion) {
      return;
    }
    if (encoded.length === 0) {
      this.isAnalyzing = false;
      this.analysisMessage = '内置示例图读取失败。';
      return;
    }
    this.selectedImageUri = '';
    // 内置示例没有文件 URI，靠这个标记让预览区改用资源图（否则页面上是空的）。
    this.isSampleImage = true;
    this.selectedImageName = '内置示例错题.png';
    this.hasPhoto = true;
    appState.addWrongQuestionImage('', this.selectedImageName);
    await this.runOnlineAnalysis(encoded, '');
  }

  /** 真正发起在线诊断（图片已编码好）。两个入口共用，行为完全一致。 */
  private async runOnlineAnalysis(encoded: string, imageUri: string): Promise<void> {
    // 调用方刚刚 ++ 过，这里读到的就是本次请求的版本号；用于丢弃过期响应
    const requestVersion: number = this.analysisRequestVersion;
    try {
      const response: AgentResponse = await AgentBridge.callAgent('帮我分析这道错题', encoded, []);
      if (!this.isPageActive || requestVersion !== this.analysisRequestVersion) {
        return;
      }
      const analysis: WrongAnalysis | undefined = response.wrongAnalysis;
      const point: string = analysis !== undefined && analysis.knowledgePoint !== undefined
        ? analysis.knowledgePoint.trim() : '';
      const wrongType: string = analysis !== undefined && analysis.wrongType !== undefined
        ? analysis.wrongType.trim() : '';
      const result: WrongAnalysisResult = {
        course: '',
        // ⚠️ 识别不出知识点时**留空**，不编一个 —— 前端据此如实回落
        // （练习页会退回默认题集），而不是拿假知识点去出题。
        knowledge: point.length > 0 ? [point] : [],
        wrongType: wrongType,
        reason: response.reply,
        suggestions: [],
        tags: [],
        imageUri: imageUri
      };
      this.analysisResult = result;
      this.showAnalysis = true;
      this.isAnalyzing = false;
      appState.latestWrongAnalysis = result;
      if (point.length === 0) {
        this.analysisMessage = '已给出分析，但没能确定具体知识点 —— 可以手动进专项练习。';
      }
    } catch (error) {
      if (!this.isPageActive || requestVersion !== this.analysisRequestVersion) {
        return;
      }
      this.isAnalyzing = false;
      this.analysisMessage = error instanceof Error
        ? error.message : '错题分析失败，请重试。';
    }
  }

  /**
   * 去练「刚刚诊断出来的那个知识点」。
   *
   * 把知识点名字作为路由参数传给练习页；后端会把名字解析成题库里的
   * `knowledgePointId`（`exercises.py::_resolve_knowledge_point_id`），
   * 于是不同错题会拿到不同题目。诊断不出知识点时退回原来的整页跳转。
   */
  private practiceDiagnosedPoint(): void {
    const points: string[] = this.analysisResult !== null ? this.analysisResult.knowledge : [];
    const point: string = points.length > 0 ? points[0].trim() : '';
    if (point.length === 0) {
      router.pushUrl({ url: 'pages/ExercisePractice' });
      return;
    }
    router.pushUrl({
      url: 'pages/ExercisePractice',
      params: { knowledgePointId: point }
    });
  }

  private addToTomorrowPlan(): void {
    if (this.analysisResult === null) {
      return;
    }
    if (appState.weeklyPlan === null) {
      appState.setWeeklyPlan(LocalAgentService.generateWeeklyPlan(
        appState.courses, appState.homeworkDDLs, appState.currentUser
      ));
    }
    const added: boolean = appState.addReviewTask(
      LocalAgentService.createWrongQuestionReviewTask(this.analysisResult),
      'Agent 已将这道错题加入明日复习，并提高了它的优先级。'
    );
    // 原缺陷：这里无条件写 `this.reviewAdded = true`，而 addReviewTask() 在该知识点
    // 已在计划中时会返回 false（没有重复添加）。于是按钮显示「已加入明日复习」，
    // 而同一次操作写进对话的文案是「已经在明日复习计划中，没有重复添加」——
    // 同屏两套说法。现在 reviewAdded 严格等于"本次是否真的新增"。
    this.reviewAdded = added;
    appState.completeChatTask(
      added ? '这道错题已加入明日复习，并已提高优先级。' : '这道错题已经在明日复习计划中，没有重复添加。',
      '现在可以确认本周复习计划。',
      '查看复习计划',
      'pages/StudyPlan'
    );
    ChatNavigation.returnToChat();
  }

  /**
   * FollowUpCard 次要按钮（加入明日复习）的文案。
   *
   * 三态取值，与 addToTomorrowPlan() 写进对话的 handoff 文案同一口径：
   *   · 本次新增成功           → 「已加入明日复习」（handoff：这道错题已加入明日复习…）
   *   · 计划里本来就有该知识点 → 「已在明日复习计划中」（handoff：已经在明日复习计划中，没有重复添加）
   *   · 还没有                 → 「加入明日复习」
   * 为什么不复用 reviewAdded 的二值：`addReviewTask()` 返回 false 时**不是失败**，
   * 而是"已经在计划中"，按钮既不能说成"什么都没做成"，也不能与 handoff 说反话。
   */
  private reviewButtonText(): string {
    if (this.reviewAdded) {
      return '已加入明日复习';
    }
    if (this.analysisResult !== null && this.analysisResult.knowledge.length > 0 &&
      appState.hasPendingWrongQuestionReview(this.analysisResult.course, this.analysisResult.knowledge[0])) {
      return '已在明日复习计划中';
    }
    return '加入明日复习';
  }

  @Builder
  AnalysisCard(result: WrongAnalysisResult) {
    Column({ space: 14 }) {
      Row() {
        Text('🤖 AI 分析结果')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#172033')
Text('✅ 分析完成')
          .fontSize(12)
          .fontColor('#2563EB')
          .fontWeight(FontWeight.Bold)
          .backgroundColor('#DBEAFE')
          .borderRadius(10)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      }
      .width('100%')

      Divider().color('#EFF6FF')

      Row({ space: 8 }) {
        Text('课程').fontSize(13).fontColor('#667085').width(60)
        Text(result.course).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#2563EB')
      }.width('100%')

      Row({ space: 8 }) {
        Text('知识点').fontSize(13).fontColor('#667085').width(60)
        Text(result.knowledge.join('、')).fontSize(14).fontColor('#344054').layoutWeight(1)
      }.width('100%')

      Row({ space: 8 }) {
        Text('错误类型').fontSize(13).fontColor('#667085').width(60)
        Text(result.wrongType).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#DC2626')
          .backgroundColor('#FEF2F2').borderRadius(6).padding({ left: 6, right: 6, top: 2, bottom: 2 })
      }.width('100%')

      Column({ space: 6 }) {
        Text('🔍 原因分析').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#2563EB').width('100%')
        Text(result.reason).fontSize(14).fontColor('#344054').lineHeight(21).width('100%')
      }.width('100%').padding(12).backgroundColor('#EFF6FF').borderRadius(12)

      if (result.suggestions.length > 0) {
        Column({ space: 8 }) {
          Text('📌 补强建议').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#2563EB').width('100%')
          ForEach(result.suggestions, (tip: string, index: number) => {
            Row({ space: 10 }) {
              Text((index + 1).toString()).fontSize(12).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
                .textAlign(TextAlign.Center).width(22).height(22).borderRadius(11).backgroundColor('#2563EB')
              Text(tip).fontSize(13).fontColor('#344054').layoutWeight(1).lineHeight(19)
            }.width('100%')
          }, (tip: string) => tip)
        }.width('100%').padding(12).backgroundColor('#EFF6FF').borderRadius(12)
      }

      if (result.tags.length > 0) {
        Row({ space: 8 }) {
          Text('🏷️').fontSize(13)
          ForEach(result.tags, (tag: string) => {
            Text(tag).fontSize(12).fontColor('#2563EB').fontWeight(FontWeight.Medium)
              .backgroundColor('#EFF6FF').borderRadius(10).padding({ left: 10, right: 10, top: 4, bottom: 4 })
          }, (tag: string) => tag)
        }.width('100%')
      }
    }
    .width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
    .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 6 })
  }

  /**
   * 诊断完成后收口「下一步」。
   *
   * 重构前的两个问题：
   *   1. 只给「加入明日复习」与「继续上传错题」，**没有通向专项练习**——
   *      诊断出了薄弱点却不让你立刻练，Agent 的第 4/5 层（行动/输出）等于断了；
   *   2. 自建了一套导航块样式，与其他页面不一致。
   * 现在统一用 FollowUpCard，主行动是**去练这个知识点**（闭环最短路径），
   * 复盘排期与继续上传降级为次要行动。
   */
  @Builder
  NavButtons() {
    Column({ space: 12 }) {
      FollowUpCard({
        title: '接下来',
        reason: this.analysisResult !== null && this.analysisResult.knowledge.length > 0
          ? `已经定位到「${this.analysisResult.knowledge[0]}」的薄弱点。立刻做几道同类题，掌握度才会真正更新。`
          : '立刻做几道同类题，掌握度才会真正更新。',
        primaryText: '做 3 道同类专项题',
        primaryTarget: 'pages/ExercisePractice',
        secondaryText: this.reviewButtonText(),
        showAgentTraceLink: true,
        // ⚠️ 必须把**诊断出的那个知识点**带到练习页。
        // 原来只用 primaryTarget 跳转（不带参数），练习页就回落到演示知识点，
        // 于是不管诊断出什么，练的永远是那同一套 3 道题 —— 用户反馈的就是这个。
        // 后端 `select_exercises` 支持按知识点从 30 题题库里选题，
        // 这里把名字传下去（后端会把名字解析成 id，见 exercises.py）。
        onPrimary: (): void => { this.practiceDiagnosedPoint(); },
        onSecondary: (): void => { this.addToTomorrowPlan(); }
      })

      Button('📸 继续上传错题')
        .width('100%').height(44).fontSize(14).fontColor('#2563EB')
        .backgroundColor('#FFFFFF').border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
        .onClick(() => {
          this.hasPhoto = false;
          this.showAnalysis = false;
          this.analysisResult = null;
          this.selectedImageUri = '';
          this.isSampleImage = false;
          this.selectedImageName = '';
          this.reviewAdded = false;
          this.analysisRequestVersion++;
          this.isAnalyzing = false;
          appState.clearCurrentWrongQuestionDraft();
        })
    }
    .width('100%')
  }

  build() {
    Stack() {
    Column() {
      Row() {
        Text('← 返回').fontSize(14).fontColor('#64748B').fontWeight(FontWeight.Medium)
          .onClick(() => { router.back(); })
        Blank()
        Text('错题诊断').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB')
          .backgroundColor('#EFF6FF').borderRadius(16).padding({ left: 12, right: 12, top: 6, bottom: 6 })
      }
      .width('100%').padding({ left: 20, right: 20, top: 12, bottom: 12 })
      .backgroundColor('#FFFFFF').shadow({ radius: 4, color: '#08000000', offsetX: 0, offsetY: 2 })

      Scroll() {
        Column({ space: 16 }) {
          Text('错题诊断')
            .fontSize(26).fontWeight(FontWeight.Bold).fontColor('#172033').width('100%')

          Text('拍照或从相册上传错题，AI 自动识别知识点、判断错误类型并生成补强建议')
            .fontSize(14).fontColor('#667085').lineHeight(21).width('100%')

          Text(appState.getChatTaskContext()).fontSize(12).fontColor('#2563EB')
            .width('100%').padding(10).backgroundColor('#EFF6FF').borderRadius(10)

          Text('当前课程：数据结构 · 选择题目—识别内容—生成补强任务')
            .fontSize(12).fontColor('#2563EB').width('100%').padding(12).backgroundColor('#EFF6FF').borderRadius(12)

          /* 上传区域 */
          Column({ space: 14 }) {
            if (!this.hasPhoto) {
              Button() {
                Row({ space: 10 }) {
                  Text('📷').fontSize(28)
                  Column({ space: 4 }) {
                    Text('上传错题图片').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                    Text('从手机相册选取清晰的错题照片').fontSize(12).fontColor('#BFDBFE')
                  }.alignItems(HorizontalAlign.Start)
                }.width('100%').padding({ left: 16, top: 14, bottom: 14 })
              }
              .width('100%').backgroundColor('#2563EB').borderRadius(16)
              .onClick(() => { this.pickFromGallery(); })

              Row({ space: 12 }) {
                Divider().color('#BFDBFE').layoutWeight(1)
                Text('或').fontSize(12).fontColor('#999')
                Divider().color('#BFDBFE').layoutWeight(1)
              }.width('100%')

              Button(this.isFixture() ? '🔄 使用模拟错题快速体验' : '🖼️ 用内置示例错题体验（真实识别）')
                .width('100%').height(44).fontSize(13).fontWeight(FontWeight.Medium)
                .fontColor('#2563EB').backgroundColor('#FFFFFF')
                .border({ width: 1, color: '#93C5FD' }).borderRadius(12)
                // ⚠️ 不能再 `enabled(this.isFixture())` —— 那会让**在线（账号）用户
                // 拿不到任何图片入口**：相册可能是空的，而唯一的体验按钮又被禁用，
                // 整页就彻底走不通了。现在在线也能用：走内置示例图 + 真实识别。
                .enabled(!this.isAnalyzing)
                .onClick(() => { this.useSampleImage(); })
            } else {
              Column({ space: 12 }) {
                Column({ space: 8 }) {
                  Row({ space: 8 }) {
                    Text('📷').fontSize(32)
                    Column({ space: 4 }) {
                      Text(this.selectedImageName).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#172033')
                      Text('图片已就绪').fontSize(12).fontColor('#2563EB')
                    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  }.width('100%')

                  if (this.isSampleImage) {
                    // 内置示例错题：图片在应用资源里，必须用 `$r` 引用 ——
                    // 直接 `Image('')` 会渲染成空白（这正是原先"没有题目照片"的原因）。
                    Image($r('app.media.sample_wrong'))
                      .width('100%').height(160).objectFit(ImageFit.Contain)
                      .backgroundColor('#EFF6FF').borderRadius(12)
                  } else if (this.selectedImageUri.startsWith('mock_')) {
                    Column({ space: 6 }) {
                      Text('📝').fontSize(48)
                      Text('模拟错题图片').fontSize(13).fontColor('#667085')
                    }
                    .width('100%').height(160).justifyContent(FlexAlign.Center)
                    .backgroundColor('#EFF6FF').borderRadius(12)
                  } else {
                    Image(this.selectedImageUri)
                      .width('100%').height(160).objectFit(ImageFit.Contain)
                      .backgroundColor('#EFF6FF').borderRadius(12)
                  }
                }
                .width('100%').padding(14).backgroundColor('#FFFFFF').borderRadius(16).border({ width: 1, color: '#EFF6FF' })

                Button('🖼️ 重新选择图片').width('100%').height(42).fontSize(13).fontWeight(FontWeight.Medium)
                  .fontColor('#2563EB').backgroundColor('#EFF6FF')
                  .border({ width: 1, color: '#93C5FD' }).borderRadius(12)
                  .onClick(() => { this.pickFromGallery(); })
              }.width('100%')
            }
          }
          .width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
          .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 6 })

          /* 加载中 */
          if (this.isAnalyzing) {
            Column({ space: 10 }) {
              LoadingProgress().width(40).height(40).color('#2563EB')
              Text('Agent 正在分析错题...').fontSize(14).fontColor('#667085')
            }
            .width('100%').padding(24).backgroundColor('#FFFFFF').borderRadius(16).border({ width: 1, color: '#EFF6FF' })
          }

          if (this.analysisMessage.length > 0) {
            Text(this.analysisMessage).fontSize(13).fontColor('#B45309').lineHeight(20).width('100%')
              .padding(12).backgroundColor('#FFFBEB').borderRadius(10)
          }

          /* 分析结果 */
          if (this.showAnalysis && this.analysisResult !== null) {
            this.AnalysisCard(this.analysisResult)
          }

          /* 导航选项 */
          if (this.showAnalysis && !this.isAnalyzing) {
            this.NavButtons()
          }
        }
        .width('100%').padding({ left: 20, right: 20, top: 16, bottom: 40 })
      }
      .layoutWeight(1)
    }
    .width('100%').height('100%').backgroundColor('#F5F7FA')
    AIFloatButton()
    }.width('100%').height('100%')
  }
}
