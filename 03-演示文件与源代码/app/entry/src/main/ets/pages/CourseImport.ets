import router from '@ohos.router';
import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { appState } from '../data/AppState';
import { CourseInfo, HomeworkDDL } from '../models/AgentModels';
import { FileParserService } from '../services/FileParserService';
import { LocalAgentService } from '../services/LocalAgentService';
import { AIFloatButton } from '../components/AIFloatButton';

@Entry
@Component
struct CourseImport {
  @State activeTab: string = 'courses';
  @State jsonInputText: string = '';
  @State importType: string = 'course';
  @State showJsonInput: boolean = false;
  @State importStatus: string = '';
  @State importMessage: string = '';
  @State imageImportName: string = '';
  @State showImageReview: boolean = false;
  @State refreshKey: number = 0;
  @State courseList: CourseInfo[] = appState.courses;
  @State ddlList: HomeworkDDL[] = appState.homeworkDDLs;

  private goBack(): void {
    try { router.back(); } catch (error) { console.error(`返回失败: ${JSON.stringify(error)}`); }
  }

  /* ==================== 文件导入 ==================== */

  private async pickAndImportFile(): Promise<void> {
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const result: string[] = await documentPicker.select();
      if (result.length === 0) return;

      const uri: string = result[0];
      const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(uri);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);

      const content: string = FileParserService.arrayBufferToString(buffer);

      if (this.activeTab === 'courses' || this.activeTab === 'import') {
        const courses: CourseInfo[] = FileParserService.autoParseCourses(content);
        appState.importCourses(courses);
        this.courseList = appState.courses;
        appState.clearWeeklyPlan();
        this.importStatus = 'success';
        this.importMessage = `成功导入 ${courses.length} 门课程`;
        this.activeTab = 'courses';
      } else {
        const ddls: HomeworkDDL[] = FileParserService.autoParseDDLs(content);
        appState.importDDLs(ddls);
        this.ddlList = appState.homeworkDDLs;
        appState.clearWeeklyPlan();
        this.importStatus = 'success';
        this.importMessage = `成功导入 ${ddls.length} 项作业`;
        this.activeTab = 'ddls';
      }
    } catch (err) {
      this.importStatus = 'error';
      this.importMessage = '文件选择失败，请使用下方手动输入方式导入数据';
      this.showJsonInput = true;
    }
  }

  /* ==================== JSON 手动导入 ==================== */

  private importFromJSONText(): void {
    if (this.jsonInputText.trim().length === 0) {
      this.importStatus = 'error';
      this.importMessage = '请输入 JSON 或 CSV 数据内容';
      return;
    }

    try {
      if (this.importType === 'course') {
        const courses: CourseInfo[] = FileParserService.autoParseCourses(this.jsonInputText);
        appState.importCourses(courses);
        this.courseList = appState.courses;
        appState.clearWeeklyPlan();
        this.importStatus = 'success';
        this.importMessage = `成功导入 ${courses.length} 门课程`;
        this.activeTab = 'courses';
      } else {
        const ddls: HomeworkDDL[] = FileParserService.autoParseDDLs(this.jsonInputText);
        appState.importDDLs(ddls);
        this.ddlList = appState.homeworkDDLs;
        appState.clearWeeklyPlan();
        this.importStatus = 'success';
        this.importMessage = `成功导入 ${ddls.length} 项作业`;
        this.activeTab = 'ddls';
      }
      this.jsonInputText = '';
      this.showJsonInput = false;
    } catch (err) {
      const errorMsg: string = (err instanceof Error) ? err.message : String(err);
      this.importStatus = 'error';
      this.importMessage = `解析失败：${errorMsg}`;
    }
  }

  private fillTemplate(): void {
    this.jsonInputText = (this.importType === 'ddl') ?
      FileParserService.generateDDLJSONTemplate() :
      FileParserService.generateCourseJSONTemplate();
  }

  private fillCSVTemplate(): void {
    this.jsonInputText = (this.importType === 'ddl') ?
      FileParserService.generateDDLCSVTemplate() :
      FileParserService.generateCourseCSVTemplate();
  }

  private resetToMock(): void {
    appState.resetToMockData();
    this.courseList = appState.courses;
    this.ddlList = appState.homeworkDDLs;
    this.importStatus = '';
    this.importMessage = '';
  }

  /* ==================== 计划跳转 ==================== */

  private openPlan(): void {
    if (appState.weeklyPlan === null) {
      appState.setWeeklyPlan(LocalAgentService.generateWeeklyPlan(
        appState.courses, appState.homeworkDDLs, appState.currentUser
      ));
    }
    router.pushUrl({ url: 'pages/StudyPlan' });
  }

  private async pickScheduleImage(): Promise<void> {
    try {
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const result = await photoPicker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      });
      if (result.photoUris.length === 0) {
        return;
      }
      this.imageImportName = `课表图片_${Date.now()}.jpg`;
      this.showImageReview = true;
      this.importStatus = 'processing';
      this.importMessage = 'Agent 已读取课表图片，正在生成可确认的课程预览。';
    } catch (error) {
      this.importStatus = 'error';
      this.importMessage = '图片选择失败，请重试或改用文件导入。';
    }
  }

  private confirmImageImport(): void {
    const recognizedCourses: CourseInfo[] = FileParserService.autoParseCourses(
      FileParserService.generateCourseJSONTemplate()
    );
    appState.importCourses(recognizedCourses);
    this.courseList = appState.courses;
    appState.clearWeeklyPlan();
    this.activeTab = 'courses';
    this.showImageReview = false;
    this.importStatus = 'success';
    this.importMessage = `已确认导入 ${recognizedCourses.length} 门课程，Agent 将据此更新学习计划。`;
  }

  /* ==================== 构建器 ==================== */

  @Builder
  CourseCard(course: CourseInfo) {
    Column() {
      Row() {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text(course.courseName).fontSize(17).fontWeight(FontWeight.Bold).fontColor('#202522')
            if (course.exam.daysLeft <= 7) {
              Text('需优先复习').fontSize(11).fontColor('#DC2626').fontWeight(FontWeight.Medium)
                .backgroundColor('#FEF2F2').borderRadius(8).padding({ left: 8, right: 8, top: 3, bottom: 3 })
            }
          }
          Text(`考试：${course.exam.date} · 倒计时 ${course.exam.daysLeft} 天`).fontSize(13).fontColor('#64748B')
          if (course.courseId.startsWith('imported') || course.courseId.startsWith('csv-import')) {
            Text('已导入').fontSize(10).fontColor('#3B82F6').fontWeight(FontWeight.Medium)
          }
        }.alignItems(HorizontalAlign.Start)
        Blank()
        Column({ space: 6 }) {
          Text(course.priority).fontSize(12).fontColor('#2563EB').fontWeight(FontWeight.Bold)
            .backgroundColor('#EFF6FF').borderRadius(10).padding({ left: 10, right: 10, top: 5, bottom: 5 })
          Text(course.recentStatus.status).fontSize(11).fontColor('#64748B')
        }.alignItems(HorizontalAlign.Center)
      }.width('100%')
      Divider().color('#F1F5F9').margin({ top: 10, bottom: 6 })
      Row() {
        Text(`本周学习 ${course.recentStatus.studyHours} 小时`).fontSize(12).fontColor('#2563EB').fontWeight(FontWeight.Medium)
        Blank()
        Text(course.recentStatus.status === '近期复习不足' ? '建议增加复习时间' : '评估状态正常')
          .fontSize(11).fontColor(course.recentStatus.status === '近期复习不足' ? '#DC2626' : '#3B82F6')
      }.width('100%')
      Row() {
        Text('查看课程计划 →').fontSize(12).fontColor('#2563EB').fontWeight(FontWeight.Medium)
          .onClick(() => this.openPlan())
        Blank()
        Text('删除').fontSize(11).fontColor('#DC2626').fontWeight(FontWeight.Medium)
          .backgroundColor('#FEF2F2').borderRadius(8)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .onClick(() => {
            appState.removeCourse(course.courseId);
            this.courseList = appState.courses;
            appState.clearWeeklyPlan();
          })
      }.width('100%').margin({ top: 8 })
    }
    .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
    .border({ width: 1, color: '#F1F5F9' })
  }

  @Builder
  DDLItem(ddl: HomeworkDDL) {
    Row() {
      Column() {
        Text(ddl.daysLeft.toString()).fontSize(26).fontWeight(FontWeight.Bold)
          .fontColor(ddl.daysLeft <= 3 ? '#DC2626' : '#2563EB')
        Text('天').fontSize(11).fontColor('#64748B')
      }
      .alignItems(HorizontalAlign.Center).width(50).height(50).borderRadius(12)
      .backgroundColor(ddl.daysLeft <= 3 ? '#FEF2F2' : '#EFF6FF').justifyContent(FlexAlign.Center)

      Column({ space: 4 }) {
        Text(ddl.title).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#202522')
        Text(`${ddl.courseName} · 截止 ${ddl.dueDate} · 预计 ${ddl.estimatedMinutes} 分钟`).fontSize(12).fontColor('#64748B')
        if (ddl.id.startsWith('ddl-imported') || ddl.id.startsWith('ddl-csv-')) {
          Text('已导入').fontSize(10).fontColor('#3B82F6').fontWeight(FontWeight.Medium)
        }
      }.alignItems(HorizontalAlign.Start).margin({ left: 12 }).layoutWeight(1)

      Column({ space: 6 }) {
        Text('加入计划').fontSize(12).fontColor('#2563EB').fontWeight(FontWeight.Medium).onClick(() => this.openPlan())
        Text(ddl.priority).fontSize(12).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
          .backgroundColor(ddl.priority === '高' ? '#DC2626' : (ddl.priority === '中' ? '#F59E0B' : '#3B82F6'))
          .borderRadius(10).padding({ left: 10, right: 10, top: 4, bottom: 4 })
        Text('删除').fontSize(10).fontColor('#DC2626').fontWeight(FontWeight.Medium)
          .backgroundColor('#FEF2F2').borderRadius(6)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .onClick(() => { appState.removeDDL(ddl.id); this.ddlList = appState.homeworkDDLs; })
      }.alignItems(HorizontalAlign.End)
    }
    .width('100%').padding(14).backgroundColor('#FFFFFF').borderRadius(14)
    .border({ width: 1, color: '#F1F5F9' })
  }

  @Builder
  ImportPanel() {
    Column({ space: 16 }) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text('图片导入').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#202522')
          Text('Agent OCR').fontSize(10).fontWeight(FontWeight.Medium).fontColor('#2563EB')
            .backgroundColor('#EFF6FF').borderRadius(8).padding({ left: 7, right: 7, top: 3, bottom: 3 })
        }.width('100%')
        Text('上传课表截图，Agent 识别课程信息后生成预览，确认后再写入学习计划。')
          .fontSize(12).fontColor('#64748B').width('100%').lineHeight(18)
        Button() {
          Row({ space: 8 }) {
            Text('▧').fontSize(18)
            Text('从相册导入课表图片').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#2563EB')
          }.justifyContent(FlexAlign.Center)
        }
        .width('100%').height(46).backgroundColor('#EFF6FF').border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
        .onClick(() => this.pickScheduleImage())

        if (this.showImageReview) {
          Column({ space: 8 }) {
            Text('识别预览').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#202522').width('100%')
            Text(`${this.imageImportName} · 已提取课程名称、考试时间与优先级`).fontSize(12).fontColor('#64748B').width('100%')
            Text('演示模式会使用本地 Agent 识别样例生成预览；接入 OCR 服务后将替换为真实图片识别结果。')
              .fontSize(11).fontColor('#7A5B2B').lineHeight(16).width('100%')
            Button('确认导入并更新计划').width('100%').height(40).fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(10).onClick(() => this.confirmImageImport())
          }.width('100%').padding(12).backgroundColor('#FFF8E8').border({ width: 1, color: '#F4D9A6' }).borderRadius(12)
        }
      }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16).border({ width: 1, color: '#F1F5F9' })

      Text('导入数据').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#202522').width('100%')

      // 方式一：文件选择
      Column({ space: 10 }) {
        Text('方式一：选择文件导入').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#202522').width('100%')
        Text('支持 JSON (.json) 和 CSV (.csv) 格式，自动识别文件类型')
          .fontSize(12).fontColor('#64748B').width('100%')

        Row({ space: 10 }) {
          Button() {
            Row({ space: 6 }) {
              Text('📂').fontSize(16)
              Text('导入课程表').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#2563EB')
            }.justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1).height(44).backgroundColor('#EFF6FF').border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
          .onClick(() => {
            this.activeTab = 'courses';
            this.pickAndImportFile();
          })

          Button() {
            Row({ space: 6 }) {
              Text('📂').fontSize(16)
              Text('导入作业DDL').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#2563EB')
            }.justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1).height(44).backgroundColor('#EFF6FF').border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
          .onClick(() => {
            this.activeTab = 'ddls';
            this.pickAndImportFile();
          })
        }.width('100%')
      }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16).border({ width: 1, color: '#F1F5F9' })

      // 方式二：手动输入
      Column({ space: 10 }) {
        Row() {
          Text('方式二：手动粘贴数据').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#202522').layoutWeight(1)
          Row({ space: 6 }) {
            Button('JSON模板').fontSize(11).height(28).fontColor('#2563EB').backgroundColor('#EFF6FF')
              .border({ width: 1, color: '#BFDBFE' }).borderRadius(8)
              .onClick(() => this.fillTemplate())
            Button('CSV模板').fontSize(11).height(28).fontColor('#2563EB').backgroundColor('#EFF6FF')
              .border({ width: 1, color: '#BFDBFE' }).borderRadius(8)
              .onClick(() => this.fillCSVTemplate())
          }
        }.width('100%')

        if (!this.showJsonInput) {
          Button() {
            Row({ space: 6 }) {
              Text('📝').fontSize(16)
              Text('点击展开手动输入区域').fontSize(13).fontColor('#2563EB')
            }.justifyContent(FlexAlign.Center)
          }
          .width('100%').height(44).backgroundColor('#EFF6FF').border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
          .onClick(() => this.showJsonInput = true)
        } else {
          // 类型选择：课程 or 作业DDL
          Text('选择导入类型：').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#202522').width('100%')
          Row({ space: 10 }) {
            Button('📚 课程表').layoutWeight(1)
              .fontSize(13).fontWeight(this.importType === 'course' ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.importType === 'course' ? '#FFFFFF' : '#2563EB')
              .backgroundColor(this.importType === 'course' ? '#2563EB' : '#EFF6FF')
              .border({ width: 1, color: '#BFDBFE' }).borderRadius(8).height(36)
              .onClick(() => this.importType = 'course')
            Button('📋 作业DDL').layoutWeight(1)
              .fontSize(13).fontWeight(this.importType === 'ddl' ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.importType === 'ddl' ? '#FFFFFF' : '#2563EB')
              .backgroundColor(this.importType === 'ddl' ? '#2563EB' : '#EFF6FF')
              .border({ width: 1, color: '#BFDBFE' }).borderRadius(8).height(36)
              .onClick(() => this.importType = 'ddl')
          }.width('100%')

          Text(this.importType === 'course' ?
            '课程CSV格式：课程名称,考试日期,优先级,学习时长,复习状态' :
            'DDL CSV格式：课程名称,作业标题,截止日期,优先级,预计时间')
            .fontSize(11).fontColor('#94A3B8').width('100%')

          TextArea({ text: this.jsonInputText, placeholder: '在此粘贴 JSON 或 CSV 内容...' })
            .fontSize(12).fontColor('#202522').backgroundColor('#F5F7FA')
            .borderRadius(10).border({ width: 1, color: '#F1F5F9' })
            .height(120).padding(12)
            .onChange((value: string) => this.jsonInputText = value)

          Row({ space: 10 }) {
            Button('解析并导入').layoutWeight(1).height(40).fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(10)
              .onClick(() => this.importFromJSONText())
            Button('收起').layoutWeight(1).height(40).fontSize(13).fontColor('#64748B')
              .backgroundColor('#F5F7FA').borderRadius(10)
              .onClick(() => {
                this.showJsonInput = false;
                this.jsonInputText = '';
              })
          }.width('100%')
        }
      }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16).border({ width: 1, color: '#F1F5F9' })

      // 恢复演示数据
      if (appState.isDataImported) {
        Button() {
          Row({ space: 6 }) {
            Text('🔄').fontSize(14)
            Text('恢复演示数据').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#64748B')
          }.justifyContent(FlexAlign.Center)
        }
        .width('100%').height(40).backgroundColor('#F5F7FA').border({ width: 1, color: '#F1F5F9' }).borderRadius(12)
        .onClick(() => this.resetToMock())
      }

      Text('导入数据后，Agent 会感知课程、考试和 DDL，生成可执行并可动态调整的本周计划。')
        .fontSize(11).fontColor('#94A3B8').width('100%').lineHeight(16)
    }.width('100%')
  }

  /* ==================== 主构建 ==================== */

  build() {
    Stack() {
    Column() {
      // 顶部导航
      Row() {
        Text('← 返回').fontSize(14).fontColor('#2563EB').fontWeight(FontWeight.Medium)
          .onClick(() => { this.goBack(); })
        Blank()
        Text('课程与作业').fontSize(13).fontColor('#2563EB').fontWeight(FontWeight.Bold)
          .backgroundColor('#EFF6FF').borderRadius(12).padding({ left: 12, right: 12, top: 6, bottom: 6 })
      }
      .width('100%').padding({ left: 20, right: 20, top: 12, bottom: 12 })
      .backgroundColor('#FFFFFF').shadow({ radius: 4, color: '#08000000', offsetX: 0, offsetY: 2 })

      // 导入状态条
      if (this.importStatus.length > 0) {
        Row() {
          Text(this.importStatus === 'success' ? '✅' : '❌').fontSize(14)
          Text(this.importMessage).fontSize(13).fontColor(this.importStatus === 'success' ? '#3B82F6' : '#DC2626')
            .layoutWeight(1)
          Text('✕').fontSize(14).fontColor('#64748B').onClick(() => { this.importStatus = ''; this.importMessage = ''; })
        }
        .width('100%').padding({ left: 20, right: 20, top: 10, bottom: 10 })
        .backgroundColor(this.importStatus === 'success' ? '#EFF6FF' : '#FEF2F2')
      }

      // Tab 切换
      Row({ space: 0 }) {
        Button() {
          Text('课程列表').fontSize(14).fontWeight(this.activeTab === 'courses' ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.activeTab === 'courses' ? '#2563EB' : '#64748B')
        }
        .layoutWeight(1).height(40).backgroundColor(this.activeTab === 'courses' ? '#EFF6FF' : '#FFFFFF')
        .border({ width: { bottom: this.activeTab === 'courses' ? 2 : 1 }, color: this.activeTab === 'courses' ? '#2563EB' : '#F1F5F9' })
        .onClick(() => this.activeTab = 'courses')

        Button() {
          Text('作业DDL').fontSize(14).fontWeight(this.activeTab === 'ddls' ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.activeTab === 'ddls' ? '#2563EB' : '#64748B')
        }
        .layoutWeight(1).height(40).backgroundColor(this.activeTab === 'ddls' ? '#EFF6FF' : '#FFFFFF')
        .border({ width: { bottom: this.activeTab === 'ddls' ? 2 : 1 }, color: this.activeTab === 'ddls' ? '#2563EB' : '#F1F5F9' })
        .onClick(() => this.activeTab = 'ddls')

        Button() {
          Text('导入').fontSize(14).fontWeight(this.activeTab === 'import' ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.activeTab === 'import' ? '#2563EB' : '#64748B')
        }
        .layoutWeight(1).height(40).backgroundColor(this.activeTab === 'import' ? '#EFF6FF' : '#FFFFFF')
        .border({ width: { bottom: this.activeTab === 'import' ? 2 : 1 }, color: this.activeTab === 'import' ? '#2563EB' : '#F1F5F9' })
        .onClick(() => this.activeTab = 'import')
      }.width('100%').padding({ left: 20, right: 20 })

      Scroll() {
        Column({ space: 16 }) {
          if (this.activeTab === 'import') {
            this.ImportPanel()
          } else if (this.activeTab === 'courses') {
            Column({ space: 4 }) {
              Row() {
                Text('已导入课程').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#202522').layoutWeight(1)
                Text(`${this.courseList.length} 门`).fontSize(12).fontColor('#2563EB').fontWeight(FontWeight.Medium)
                  .backgroundColor('#EFF6FF').borderRadius(10).padding({ left: 10, right: 10, top: 4, bottom: 4 })
              }.width('100%').margin({ bottom: 8 })

              if (this.courseList.length === 0) {
                Column({ space: 8 }) {
                  Text('📭').fontSize(36)
                  Text('还没有课程数据').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#64748B')
                  Text('点击上方「导入」标签导入课程表').fontSize(12).fontColor('#94A3B8')
                  Button('前往导入').fontSize(13).fontColor('#2563EB').backgroundColor('#EFF6FF')
                    .border({ width: 1, color: '#BFDBFE' }).borderRadius(8).margin({ top: 4 })
                    .onClick(() => this.activeTab = 'import')
                }.width('100%').padding(24).alignItems(HorizontalAlign.Center)
              } else {
                ForEach(this.courseList, (course: CourseInfo) => {
                  this.CourseCard(course)
                }, (course: CourseInfo) => course.courseId)
              }
            }.width('100%')
          } else if (this.activeTab === 'ddls') {
            Column({ space: 4 }) {
              Row() {
                Text('作业 DDL').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#202522').layoutWeight(1)
                Text(`${appState.getUrgentDDLs().length} 项紧急`).fontSize(12).fontColor('#DC2626').fontWeight(FontWeight.Medium)
                  .backgroundColor('#FEF2F2').borderRadius(10).padding({ left: 10, right: 10, top: 4, bottom: 4 })
              }.width('100%').margin({ bottom: 8 })

              if (this.ddlList.length === 0) {
                Column({ space: 8 }) {
                  Text('📭').fontSize(36)
                  Text('还没有作业DDL数据').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#64748B')
                  Text('点击上方「导入」标签导入作业列表').fontSize(12).fontColor('#94A3B8')
                  Button('前往导入').fontSize(13).fontColor('#2563EB').backgroundColor('#EFF6FF')
                    .border({ width: 1, color: '#BFDBFE' }).borderRadius(8).margin({ top: 4 })
                    .onClick(() => this.activeTab = 'import')
                }.width('100%').padding(24).alignItems(HorizontalAlign.Center)
              } else {
                ForEach(this.ddlList, (ddl: HomeworkDDL) => {
                  this.DDLItem(ddl)
                }, (ddl: HomeworkDDL) => ddl.id)
              }
            }.width('100%')
          }
        }
        .width('100%').padding({ left: 20, right: 20, top: 16, bottom: 40 })
      }
      .layoutWeight(1)

      // 底部导航
      Row({ space: 0 }) {
        Button() {
          Row({ space: 6 }) {
            Text('🏠').fontSize(18)
            Text('返回首页').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB')
          }.justifyContent(FlexAlign.Center)
        }
        .layoutWeight(1).height(52).backgroundColor('#EFF6FF').border({ width: 1, color: '#BFDBFE' }).borderRadius(0)
        .onClick(() => { router.pushUrl({ url: 'pages/Index' }); })

        Button() {
          Row({ space: 6 }) {
            Text('📋').fontSize(18)
            Text('本周计划').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB')
          }.justifyContent(FlexAlign.Center)
        }
        .layoutWeight(1).height(52).backgroundColor('#EFF6FF').border({ width: 1, color: '#BFDBFE' }).borderRadius(0)
        .onClick(() => { this.openPlan(); })
      }
      .width('100%')
    }
    .width('100%').height('100%').backgroundColor('#FFFFFF')
    AIFloatButton()
    }.width('100%').height('100%')
  }
}
