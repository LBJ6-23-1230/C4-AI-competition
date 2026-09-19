const formStorage: LocalStorage = new LocalStorage();

@Entry(formStorage)
@Component
struct LearningCard {
  @LocalStorageProp('cardTitle') cardTitle: string = '今日学习建议';
  @LocalStorageProp('taskName') taskName: string = '打开知学搭子，生成当前任务';
  @LocalStorageProp('reason') reason: string = '根据考试、薄弱点和可用时间，给出下一步行动。';
  @LocalStorageProp('durationText') durationText: string = '待生成';
  @LocalStorageProp('actionText') actionText: string = '打开应用';

  build() {
    FormLink({
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        source: 'learning_card',
        initialTab: 2
      }
    }) {
      Column({ space: 8 }) {
        Row() {
          Text('知学 MATE').fontSize(11).fontWeight(FontWeight.Bold).fontColor('#1D4ED8')
          Blank()
          Text(this.durationText)
            .fontSize(11).fontColor('#1D4ED8')
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor('#DBEAFE').borderRadius(10)
        }
        .width('100%')

        Text(this.taskName)
          .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#0F172A')
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')

        Text(this.reason)
          .fontSize(12).fontColor('#475569').lineHeight(17)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')

        Blank()

        Row() {
          Text(this.actionText).fontSize(13).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
          Text('  →').fontSize(13).fontColor('#FFFFFF')
        }
        .justifyContent(FlexAlign.Center).width('100%').height(34)
        .backgroundColor('#2563EB').borderRadius(10)
      }
      .width('100%').height('100%').padding(16)
      .backgroundColor('#F8FAFC').borderRadius(18)
    }
  }
}
