import router from '@ohos.router';
import { appState } from '../data/AppState';
import { LearningBadge, LearningPlanTask, LearningReview } from '../models/AgentModels';
import { AIFloatButton } from '../components/AIFloatButton';

@Entry
@Component
struct ReviewSummary {
  private completedTasks(): LearningPlanTask[] {
    return appState.weeklyPlan?.tasks.filter((t: LearningPlanTask) => t.status === 'completed') ?? [];
  }

  private pendingTasks(): LearningPlanTask[] {
    return appState.weeklyPlan?.tasks.filter((t: LearningPlanTask) => t.status !== 'completed').slice(0, 3) ?? [];
  }

  private reviewedKnowledge(): string[] {
    const vals: string[] = [];
    this.completedTasks().forEach((t: LearningPlanTask) => {
      if (vals.indexOf(t.knowledgePoint) === -1) vals.push(t.knowledgePoint);
    });
    return vals;
  }

  private focusMinutes(): number { return appState.getFocusSummary().todayMinutes; }
  private focusCompletionRate(): number { return appState.getFocusSummary().completionRate; }
  private review(): LearningReview | null { return appState.latestReview; }

  build() {
    Stack() {
    Column() {
      Row() {
        Text('← 返回').fontSize(14).fontColor('#64748B').onClick(() => router.back())
        Blank()
        Text('学习复盘').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB')
      }.width('100%').padding({ left: 20, right: 20, top: 18, bottom: 14 }).backgroundColor('#FFFFFF')

      Scroll() {
        Column({ space: 16 }) {
          Text('今天的学习，已经被记录。').fontSize(25).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
          Text('所有数据来自本次计划与专注记录。').fontSize(13).fontColor('#667085').width('100%')
          Row({ space: 10 }) {
            this.Metric(`${this.focusMinutes()} 分钟`, '实际专注')
            this.Metric(`${this.focusCompletionRate()}%`, '平均完成率')
            this.Metric(`${this.completedTasks().length}`, '完成任务')
          }.width('100%')

          Column({ space: 10 }) {
            Text('已完成').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
            if (this.completedTasks().length === 0) {
              Text('还没有完成任务。完成一次专注后，Agent 会同步更新。').fontSize(13).fontColor('#667085')
                .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(14)
            } else {
              ForEach(this.completedTasks(), (task: LearningPlanTask) => {
                Row({ space: 10 }) {
                  Text('✓').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                    .width(26).height(26).textAlign(TextAlign.Center).borderRadius(13).backgroundColor('#2563EB')
                  Column({ space: 2 }) {
                    Text(task.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor('#1F2937')
                    Text(`${task.course} · ${task.knowledgePoint}`).fontSize(12).fontColor('#667085')
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                }.width('100%').padding(14).backgroundColor('#FFFFFF').borderRadius(14)
              }, (task: LearningPlanTask) => task.id)
            }
          }.width('100%').padding(18).backgroundColor('#EFF6FF').borderRadius(18)

          Column({ space: 8 }) {
            Text('知识点回顾').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
            if (this.reviewedKnowledge().length === 0) {
              Text('完成任务后会自动沉淀知识点。').fontSize(13).fontColor('#667085')
            } else {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.reviewedKnowledge(), (k: string) => {
                  Text(k).fontSize(13).fontColor('#2563EB').backgroundColor('#EFF6FF').borderRadius(12)
                    .padding({ left: 10, right: 10, top: 6, bottom: 6 }).margin({ right: 8, bottom: 8 })
                }, (k: string) => k)
              }.width('100%')
            }
          }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18).border({ width: 1, color: '#EAECF0' })

          if (this.review() !== null && this.review()!.badges.length > 0) {
            Column({ space: 10 }) {
              Text('本次收获').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
              ForEach(this.review()!.badges, (badge: LearningBadge) => {
                Row({ space: 10 }) {
                  Text(badge.icon).fontSize(24)
                  Column({ space: 2 }) {
                    Text(badge.name).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#1F2937')
                    Text(badge.description).fontSize(12).fontColor('#667085')
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                }.width('100%').padding(12).backgroundColor('#EFF6FF').borderRadius(12)
              }, (badge: LearningBadge) => badge.name)
            }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18).border({ width: 1, color: '#EAECF0' })
          }

          if (appState.latestPartner !== null) {
            Text(`学习搭子：${appState.latestPartner!.matchName} · ${appState.latestPartner!.score}% 匹配`)
              .fontSize(13).fontColor('#2563EB').width('100%').padding(13).backgroundColor('#EFF6FF').borderRadius(12)
          }

          Column({ space: 8 }) {
            Text('Agent 的下一步').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
            Text(appState.weeklyPlan?.adjustmentMessage ?? '完成首项任务后，Agent 会生成下一步安排。').fontSize(13).fontColor('#475467').lineHeight(20)
            ForEach(this.pendingTasks(), (task: LearningPlanTask, idx: number) => {
              Text(`${idx + 1}. ${task.title} · ${task.plannedMinutes} 分钟`).fontSize(13).fontColor('#1F2937')
                .width('100%').padding(12).backgroundColor('#F7F8FA').borderRadius(10)
            }, (task: LearningPlanTask) => task.id)
          }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18).border({ width: 1, color: '#EAECF0' })

          Button('查看更新后的计划').width('100%').height(48).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            .backgroundColor('#2563EB').borderRadius(14).margin({ bottom: 8 })
            .onClick(() => router.pushUrl({ url: 'pages/StudyPlan' }))

          Button('💬 问知学Mate').fontSize(14).fontColor('#2563EB').backgroundColor('#EFF6FF')
            .height(44).borderRadius(14).width('100%').margin({ bottom: 20 })
            .onClick(() => {
              appState.setChatPrompt('帮我总结一下今天的学习');
              router.pushUrl({ url: 'pages/ChatMain' });
            })
        }.width('100%').padding(20)
      }.layoutWeight(1)
    }.width('100%').height('100%').backgroundColor('#F7F8FA')
    AIFloatButton()
    }.width('100%').height('100%')
  }

  @Builder
  Metric(value: string, label: string) {
    Column({ space: 4 }) {
      Text(value).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1F2937')
      Text(label).fontSize(11).fontColor('#667085')
    }.layoutWeight(1).alignItems(HorizontalAlign.Center).padding(13).backgroundColor('#FFFFFF').borderRadius(14)
  }
}
