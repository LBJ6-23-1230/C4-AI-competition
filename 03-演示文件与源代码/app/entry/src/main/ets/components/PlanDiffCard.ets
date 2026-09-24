import { PlanDiff, PlanTaskChange } from '../api/ApiModels';
import { ApiDisplayFormatter } from '../utils/ApiDisplayFormatter';

@Component
export struct PlanDiffCard {
  @Prop value: PlanDiff;

  private changeLabel(change: PlanTaskChange): string {
    if (change.change === undefined || change.change.trim().length === 0) {
      return '时长已调整';
    }
    const raw: string = change.change.trim();
    if (raw.endsWith('分钟')) {
      return raw;
    }
    return `${raw} 分钟`;
  }

  private durationLabel(change: PlanTaskChange): string {
    if (change.durationMinutes === undefined) {
      return '';
    }
    return `调整后 ${change.durationMinutes} 分钟`;
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 3 }) {
          Text('学习计划已更新').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#111827')
          Text(`Plan V${this.value.oldVersion} → V${this.value.newVersion}`)
            .fontSize(13).fontColor('#2563EB').fontWeight(FontWeight.Medium)
        }.alignItems(HorizontalAlign.Start)
        Blank()
        Text(`${this.value.changedTasks.length} 项调整`).fontSize(11).fontColor('#2563EB')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 }).backgroundColor('#EFF6FF').borderRadius(9)
      }.width('100%')

      Text(this.value.adjustmentReason.length > 0 ? this.value.adjustmentReason : 'Agent 已根据本次评估更新学习计划。')
        .fontSize(13).fontColor('#475467').lineHeight(19).width('100%')

      if (this.value.changedTasks.length > 0) {
        ForEach(this.value.changedTasks, (change: PlanTaskChange) => {
          Column({ space: 6 }) {
            Text(ApiDisplayFormatter.knowledgePoint(change.knowledgePointId ?? change.taskId))
              .fontSize(14).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
            Row() {
              Text(this.changeLabel(change)).fontSize(13)
                .fontColor(change.change?.startsWith('-') ? '#B45309' : '#0F766E')
              Blank()
              if (change.durationMinutes !== undefined) {
                Text(this.durationLabel(change)).fontSize(12).fontColor('#667085')
              }
            }.width('100%')
          }.width('100%').padding(12).backgroundColor('#F8FAFC').borderRadius(10)
        }, (change: PlanTaskChange) => change.taskId)
      } else {
        Text('本次评估未产生具体任务调整。').fontSize(13).fontColor('#667085')
          .width('100%').padding(12).backgroundColor('#F8FAFC').borderRadius(10)
      }

      if (this.value.triggerEvidence.length > 0) {
        Text(`触发证据：${this.value.triggerEvidence.join('、')}`)
          .fontSize(12).fontColor('#667085').lineHeight(18).width('100%')
      }
    }.width('100%').padding(14).backgroundColor('#FFFFFF')
      .border({ width: 1, color: '#BFDBFE' }).borderRadius(14)
  }
}
