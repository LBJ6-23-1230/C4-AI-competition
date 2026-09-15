import router from '@ohos.router';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { appState } from '../data/AppState';
import { WrongAnalysisResult } from '../models/AgentModels';
import { LocalAgentService } from '../services/LocalAgentService';
import { ChatNavigation } from '../services/ChatNavigation';
import { AIFloatButton } from '../components/AIFloatButton';

@Entry
@Component
struct WrongQuestion {
  @State hasPhoto: boolean = false;
  @State selectedImageUri: string = '';
  @State selectedImageName: string = '';
  @State isAnalyzing: boolean = false;
  @State analysisResult: WrongAnalysisResult | null = null;
  @State showAnalysis: boolean = false;
  @State reviewAdded: boolean = false;
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
      this.reviewAdded = appState.hasPendingWrongQuestionReview(
        appState.latestWrongAnalysis.course,
        appState.latestWrongAnalysis.knowledge[0] ?? '错题知识点'
      );
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
        this.selectedImageName = `photo_${Date.now()}.jpg`;
        this.hasPhoto = true;
        appState.addWrongQuestionImage(uri, this.selectedImageName);
        this.startAnalysis(uri);
      }
    } catch (error) {
      console.error(`选图失败: ${JSON.stringify(error)}`);
      this.useMockImage();
    }
  }

  private async takePhoto(): Promise<void> {
    try {
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const result = await photoPicker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      });
      if (result.photoUris.length > 0) {
        const uri: string = result.photoUris[0];
        this.selectedImageUri = uri;
        this.selectedImageName = `camera_${Date.now()}.jpg`;
        this.hasPhoto = true;
        appState.addWrongQuestionImage(uri, this.selectedImageName);
        this.startAnalysis(uri);
      }
    } catch (error) {
      console.error(`拍照失败: ${JSON.stringify(error)}`);
      this.useMockImage();
    }
  }

  private useMockImage(): void {
    const mockUri: string = `mock_${Date.now()}.jpg`;
    this.selectedImageUri = mockUri;
    this.selectedImageName = '模拟错题图片.jpg';
    this.hasPhoto = true;
    appState.addWrongQuestionImage(mockUri, this.selectedImageName);
    this.startAnalysis(mockUri);
  }

  private startAnalysis(imageUri: string): void {
    const requestVersion: number = ++this.analysisRequestVersion;
    this.isAnalyzing = true;
    this.showAnalysis = false;
    this.analysisResult = null;
    this.reviewAdded = false;
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
    this.reviewAdded = true;
    appState.completeChatTask(
      added ? '这道错题已加入明日复习，并已提高优先级。' : '这道错题已经在明日复习计划中，没有重复添加。',
      '现在可以确认本周复习计划。',
      '查看复习计划',
      'pages/StudyPlan'
    );
    ChatNavigation.returnToChat();
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

  @Builder
  NavButtons() {
    Column({ space: 8 }) {
      Text('接下来想做什么？').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#172033').width('100%')

      Button() {
        Row({ space: 8 }) {
          Text(this.reviewAdded ? '已加入明日复习' : '加入明日复习').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
Text('→').fontSize(16).fontColor('#FFFFFF')
        }.width('100%').padding({ left: 16, right: 16 })
      }
      .width('100%').height(48).backgroundColor(this.reviewAdded ? '#94A3B8' : '#2563EB').borderRadius(14)
      .enabled(!this.reviewAdded)
      .onClick(() => this.addToTomorrowPlan())

      Button() {
        Row({ space: 8 }) {
          Text('📸').fontSize(18)
          Text('继续上传错题').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#2563EB')
Text('→').fontSize(16).fontColor('#2563EB')
        }.width('100%').padding({ left: 16, right: 16 })
      }
      .width('100%').height(46).backgroundColor('#EFF6FF').border({ width: 1, color: '#93C5FD' }).borderRadius(14)
      .onClick(() => {
        this.hasPhoto = false;
        this.showAnalysis = false;
        this.analysisResult = null;
        this.selectedImageUri = '';
        this.selectedImageName = '';
        this.reviewAdded = false;
        this.analysisRequestVersion++;
        this.isAnalyzing = false;
        appState.clearCurrentWrongQuestionDraft();
      })
    }
    .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
    .shadow({ radius: 8, color: '#10000000', offsetX: 0, offsetY: 3 })
  }

  build() {
    Stack() {
    Column() {
      Row() {
        Text('← 返回').fontSize(14).fontColor('#64748B').fontWeight(FontWeight.Medium)
          .onClick(() => { router.back(); })
        Blank()
        Text('错题分析').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB')
          .backgroundColor('#EFF6FF').borderRadius(16).padding({ left: 12, right: 12, top: 6, bottom: 6 })
      }
      .width('100%').padding({ left: 20, right: 20, top: 12, bottom: 12 })
      .backgroundColor('#FFFFFF').shadow({ radius: 4, color: '#08000000', offsetX: 0, offsetY: 2 })

      Scroll() {
        Column({ space: 16 }) {
          Text('错题分析')
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
                    Text('拍照识别').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                    Text('使用相机拍摄错题').fontSize(12).fontColor('#BFDBFE')
                  }.alignItems(HorizontalAlign.Start)
                }.width('100%').padding({ left: 16, top: 14, bottom: 14 })
              }
              .width('100%').backgroundColor('#2563EB').borderRadius(16)
              .onClick(() => { this.takePhoto(); })

              Button() {
                Row({ space: 10 }) {
                  Text('🖼️').fontSize(28)
                  Column({ space: 4 }) {
                    Text('从相册选择').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#2563EB')
                    Text('从手机相册选取错题图片').fontSize(12).fontColor('#3B82F6')
                  }.alignItems(HorizontalAlign.Start)
                }.width('100%').padding({ left: 16, top: 14, bottom: 14 })
              }
              .width('100%').backgroundColor('#EFF6FF').border({ width: 1.5, color: '#93C5FD' }).borderRadius(16)
              .onClick(() => { this.pickFromGallery(); })

              Row({ space: 12 }) {
                Divider().color('#BFDBFE').layoutWeight(1)
                Text('或').fontSize(12).fontColor('#999')
                Divider().color('#BFDBFE').layoutWeight(1)
              }.width('100%')

              Button('🔄 使用模拟错题快速体验')
                .width('100%').height(44).fontSize(13).fontWeight(FontWeight.Medium)
                .fontColor('#2563EB').backgroundColor('#FFFFFF')
                .border({ width: 1, color: '#93C5FD' }).borderRadius(12)
                .onClick(() => { this.useMockImage(); })
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

                  Column() {
                    Text('📝').fontSize(48)
                    Text('错题图片预览').fontSize(13).fontColor('#667085')
                  }
                  .width('100%').height(120).justifyContent(FlexAlign.Center)
                  .backgroundColor('#EFF6FF').borderRadius(12).border({ width: 1, color: '#93C5FD' })
                }
                .width('100%').padding(14).backgroundColor('#FFFFFF').borderRadius(16).border({ width: 1, color: '#EFF6FF' })

                Row({ space: 10 }) {
                  Button('📷 重拍').layoutWeight(1).height(42).fontSize(13).fontWeight(FontWeight.Medium)
                    .fontColor('#2563EB').backgroundColor('#EFF6FF').border({ width: 1, color: '#93C5FD' }).borderRadius(12)
                    .onClick(() => { this.takePhoto(); })
                  Button('🖼️ 重选').layoutWeight(1).height(42).fontSize(13).fontWeight(FontWeight.Medium)
                    .fontColor('#2563EB').backgroundColor('#EFF6FF').border({ width: 1, color: '#93C5FD' }).borderRadius(12)
                    .onClick(() => { this.pickFromGallery(); })
                }.width('100%')
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
