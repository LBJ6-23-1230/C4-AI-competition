import router from '@ohos.router';
import { appState } from '../data/AppState';
import { FocusSession, FocusSummary } from '../models/AgentModels';
import { AIFloatButton } from '../components/AIFloatButton';

@Entry
@Component
struct LearningHistory {
  build() {
    Stack() {
    Column() {
      Row() { Text('返回').fontSize(14).fontColor('#2563EB').onClick(() => router.back()); Blank(); Text('我的记录').fontSize(14).fontWeight(FontWeight.Medium).fontColor('#2563EB') }
        .width('100%').padding(20).backgroundColor('#FFFFFF')
      Scroll() {
        Column({ space: 16 }) {
          Text('把每一次投入，留给自己。').fontSize(25).fontWeight(FontWeight.Bold).fontColor('#202522').width('100%')
          Row({ space: 10 }) { this.Metric(`${appState.getFocusSummary().todayMinutes}`, '今日分钟'); this.Metric(`${appState.getFocusSummary().completionRate}%`, '平均完成率'); this.Metric(`${appState.getFocusSummary().streakDays}`, '连续天数') }.width('100%')
          Column({ space: 10 }) {
            Text('课程时长').fontSize(16).fontWeight(FontWeight.Medium).fontColor('#202522').width('100%')
            if (appState.getFocusSummary().courseMinutes.size === 0) Text('完成一次专注后，这里会记下你的投入。').fontSize(13).fontColor('#64748B')
            ForEach(Array.from(appState.getFocusSummary().courseMinutes.entries()), (item: [string, number]) => {
              Row() { Text(item[0]).fontSize(15).fontColor('#202522'); Blank(); Text(`${item[1]} 分钟`).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#2563EB') }
                .width('100%').padding(14).backgroundColor('#FFFFFF').borderRadius(14).border({ width: 1, color: '#F1F5F9' })
            }, (item: [string, number]) => item[0])
          }.width('100%').padding(18).backgroundColor('#F5F7FA').borderRadius(20)
          Column({ space: 10 }) {
            Text('最近专注').fontSize(16).fontWeight(FontWeight.Medium).fontColor('#202522').width('100%')
            if (appState.getFocusSummary().recentSessions.length === 0) Text('还没有记录。先从 25 分钟开始就很好。').fontSize(13).fontColor('#64748B')
            ForEach(appState.getFocusSummary().recentSessions, (session: FocusSession) => {
              Column({ space: 4 }) { Row() { Text(session.task).fontSize(15).fontWeight(FontWeight.Medium).fontColor('#202522').layoutWeight(1); Text(`${session.completionRate}%`).fontSize(14).fontColor('#2563EB') }; Text(`${session.course} · ${session.actualMinutes} 分钟 · ${session.endedAt}`).fontSize(12).fontColor('#64748B') }
                .width('100%').padding(14).backgroundColor('#FFFFFF').borderRadius(14).border({ width: 1, color: '#F1F5F9' })
            }, (session: FocusSession) => session.taskId)
          }.width('100%').padding(18).backgroundColor('#F5F7FA').borderRadius(20)
          Button('开始一次专注').width('100%').height(52).fontColor('#FFFFFF').fontWeight(FontWeight.Bold).backgroundColor('#2563EB').borderRadius(16).onClick(() => router.pushUrl({ url: 'pages/FocusSetup' }))
        }.width('100%').padding(20)
      }.layoutWeight(1)
    }.width('100%').height('100%').backgroundColor('#FFFFFF')
    AIFloatButton()
    }.width('100%').height('100%')
  }

  @Builder
  Metric(value: string, label: string) { Column({ space: 4 }) { Text(value).fontSize(20).fontWeight(FontWeight.Bold).fontColor('#2563EB'); Text(label).fontSize(11).fontColor('#64748B') }.layoutWeight(1).alignItems(HorizontalAlign.Center).padding(14).backgroundColor('#EFF6FF').borderRadius(16) }
}
