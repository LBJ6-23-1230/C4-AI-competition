import router from '@ohos.router';
import { appState } from '../data/AppState';
import { StudySuggestion as StudySuggestionType, CourseInfo, TaskPriority, FocusTask } from '../models/AgentModels';
import { LocalAgentService } from '../services/LocalAgentService';
import { ChatNavigation } from '../services/ChatNavigation';
import { AIFloatButton } from '../components/AIFloatButton';

let highPriorityCourse: CourseInfo = appState.getHighPriorityCourse();
let generatedSuggestion: StudySuggestionType =
  LocalAgentService.generateStudySuggestions(appState.currentUser, highPriorityCourse);
let allTasks: TaskPriority[] =
  LocalAgentService.judgeOptimalTask(appState.courses, appState.homeworkDDLs, appState.currentUser);

@Entry
@Component
struct StudySuggestion {
  aboutToAppear(): void {
    highPriorityCourse = appState.getHighPriorityCourse();
    generatedSuggestion = LocalAgentService.generateStudySuggestions(appState.currentUser, highPriorityCourse);
    allTasks = LocalAgentService.judgeOptimalTask(appState.courses, appState.homeworkDDLs, appState.currentUser);
    appState.latestSuggestion = generatedSuggestion;
  }

  private goBack(): void {
    appState.leaveChatTask();
    router.back();
  }

  private startSuggestedFocus(): void {
    const minutes: number = Number(generatedSuggestion.duration.replace(/[^0-9]/g, '')) || 30;
    const task: FocusTask = { course: generatedSuggestion.course, task: generatedSuggestion.task, plannedMinutes: minutes, source: 'agent', mode: 'normal', timerType: 'countdown' };
    appState.setFocusTask(task);
    router.pushUrl({ url: 'pages/FocusSetup' });
  }

  build() {
    Stack() {
    Column() {
      Row() {
        Text('← 返回').fontSize(14).fontColor('#64748B').fontWeight(FontWeight.Medium)
          .onClick(() => { this.goBack(); })
Text('学习建议').fontSize(13).fontColor('#2563EB').fontWeight(FontWeight.Bold)
          .backgroundColor('#E0EEFF').borderRadius(16).padding({ left: 12, right: 12, top: 6, bottom: 6 })
      }
      .width('100%').padding({ left: 20, right: 20, top: 12, bottom: 12 })
      .backgroundColor('#FFFFFF').shadow({ radius: 4, color: '#08000000', offsetX: 0, offsetY: 2 })

      Scroll() {
        Column({ space: 18 }) {
          Text('今日学习建议')
            .fontSize(26).fontWeight(FontWeight.Bold).fontColor('#172033').width('100%')

          // 数据来源标识
          Row({ space: 6 }) {
            Text(appState.isDataImported ? '📥' : '📋').fontSize(12)
            Text(appState.isDataImported ? '基于导入数据 · Agent分析' : '基于演示数据 · Agent分析')
              .fontSize(11).fontColor(appState.isDataImported ? '#2563EB' : '#667085')
Text(`${appState.courses.length}门课程 · ${appState.homeworkDDLs.length}项作业`)
              .fontSize(11).fontColor('#94A3B8')
          }
          .width('100%').padding(10).backgroundColor(appState.isDataImported ? '#EFF6FF' : '#F5F7FA').borderRadius(10)

          /* 主要建议 */
          Column({ space: 12 }) {
            Row() {
              Text('Agent 建议').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#172033').layoutWeight(1)
              Text(generatedSuggestion.priority).fontSize(12).fontColor('#FFFFFF')
                .backgroundColor(generatedSuggestion.priority === '高' ? '#DC2626' : '#F59E0B')
                .borderRadius(14).padding({ left: 10, right: 10, top: 5, bottom: 5 })
            }.width('100%')

            Text(generatedSuggestion.reason).fontSize(15).fontColor('#4B5565').lineHeight(22)

            Text(appState.getChatTaskContext()).fontSize(12).fontColor('#2563EB')
              .width('100%').padding(10).backgroundColor('#EFF6FF').borderRadius(10)

            Button('立即专注')
              .width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
              .backgroundColor('#2563EB').borderRadius(14).onClick(() => this.startSuggestedFocus())

            ForEach([
              `课程：${generatedSuggestion.course}`,
              `任务：${generatedSuggestion.task}`,
              `建议时长：${generatedSuggestion.duration}`,
              `考试倒计时：${highPriorityCourse.exam.daysLeft} 天`,
              `数据来源：${appState.isDataImported ? '导入文件数据' : '示例数据'}`
            ], (item: string) => {
              Row({ space: 8 }) {
                Text('').width(7).height(7).borderRadius(4).backgroundColor('#2563EB')
                Text(item).fontSize(14).fontColor('#344054').layoutWeight(1)
              }.width('100%')
            }, (item: string) => item)
          }
          .width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
          .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 6 })

          /* 评分依据 */
          Column({ space: 8 }) {
            Text('📊 评分依据').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#667085').width('100%')
            ForEach([
              `📅 考试紧迫：距离考试仅 ${highPriorityCourse.exam.daysLeft} 天`,
              `📊 复习状态：${highPriorityCourse.recentStatus.status}（本周${highPriorityCourse.recentStatus.studyHours}小时）`,
              `🎯 薄弱知识点：${appState.currentUser.knowledge.weakness.join('、')}`,
              appState.isDataImported ?
                `📥 已导入 ${appState.importedCourseCount} 门课程、${appState.importedDDLCount} 项作业` :
                `📋 当前使用演示数据（3门课程、5项作业）`
            ], (factor: string) => {
              Text(factor).fontSize(13).fontColor('#344054').width('100%').padding({ left: 4 })
            }, (factor: string) => factor)
          }
          .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
          .shadow({ radius: 8, color: '#10000000', offsetX: 0, offsetY: 3 })

          /* 任务排序 */
          Column({ space: 4 }) {
            Text('📋 所有任务排序').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#667085')
              .width('100%').margin({ bottom: 4 })

            if (allTasks.length === 0) {
              Text('暂无课程数据，请先在课程页面导入课程表')
                .fontSize(13).fontColor('#667085').width('100%').padding(12)
            }

            ForEach(allTasks, (task: TaskPriority, index: number) => {
              Row() {
                Text((index + 1).toString()).fontSize(14).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
                  .textAlign(TextAlign.Center).width(24).height(24).borderRadius(12)
                  .backgroundColor(index === 0 ? '#DC2626' : '#2563EB')
                Column({ space: 2 }) {
                  Text(task.task).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#172033')
                  Text(task.urgencyFactors.join(' · ')).fontSize(11).fontColor('#667085')
                }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
                Text(`${task.priorityScore}分`).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB')
              }
              .width('100%').padding(12).backgroundColor('#FFFFFF').borderRadius(12)
            }, (task: TaskPriority) => task.courseName + task.task)
          }
          .width('100%').padding(16).backgroundColor('#F5F7FA').borderRadius(16)

          Button('返回上一页')
            .width('100%').height(42).fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor('#2563EB').backgroundColor('#FFFFFF').border({ width: 1, color: '#B8D0F0' }).borderRadius(12)
            .onClick(() => this.goBack())

          if (!appState.isDataImported) {
            Text('资料不足时，可在对话里补充课程表或 DDL。')
              .fontSize(12).fontColor('#667085').width('100%').textAlign(TextAlign.Center)
              .padding(6)
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
