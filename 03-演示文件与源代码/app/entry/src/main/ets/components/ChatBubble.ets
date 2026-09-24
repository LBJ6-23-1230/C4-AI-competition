import { ChatCard, ChatMessage } from '../models/ChatModels';

@Component
export struct ChatBubble {
  @Prop message: ChatMessage;

  private isUser(): boolean {
    return this.message.role === 'user';
  }

  build() {
    Row() {
      if (this.isUser()) {
        Blank()
      }

      Column({ space: 8 }) {
        if (this.message.image !== undefined && this.message.image.length > 0) {
          Image(this.message.image)
            .width(112)
            .height(84)
            .objectFit(ImageFit.Cover)
            .borderRadius(8)
            .backgroundColor('#E2E8F0')
        }

        if (this.message.status === 'sending') {
          Row({ space: 5 }) {
            Text('').width(6).height(6).borderRadius(3).backgroundColor('#8E99A8')
            Text('').width(6).height(6).borderRadius(3).backgroundColor('#B3BBC6')
            Text('').width(6).height(6).borderRadius(3).backgroundColor('#D0D6DE')
          }
          .padding({ left: 14, right: 14, top: 12, bottom: 12 })
          .backgroundColor('#FFFFFF')
          .borderRadius(8)
        } else {
          Text(this.message.text)
            .fontSize(15)
            .lineHeight(22)
            .fontColor(this.isUser() ? '#FFFFFF' : '#1F2933')
            .padding({ left: 14, right: 14, top: 11, bottom: 11 })
            .backgroundColor(this.isUser() ? '#2563EB' : '#FFFFFF')
            .borderRadius(8)
        }

        if (this.message.card !== undefined) {
          this.CardView(this.message.card)
        }
      }
      .alignItems(this.isUser() ? HorizontalAlign.End : HorizontalAlign.Start)
      .width('78%')

      if (!this.isUser()) {
        Blank()
      }
    }
    .width('100%')
    .justifyContent(this.isUser() ? FlexAlign.End : FlexAlign.Start)
    .padding({ left: 16, right: 16, top: 5, bottom: 5 })
  }

  @Builder
  private CardView(card: ChatCard) {
    Column({ space: 6 }) {
      Row() {
        Text(this.getCardLabel(card))
          .fontSize(12)
          .fontColor('#2563EB')
          .fontWeight(FontWeight.Medium)
        Blank()
        Text('查看')
          .fontSize(12)
          .fontColor('#64748B')
      }
      .width('100%')

      Text(card.title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#111827')
        .maxLines(1)
      Text(card.summary)
        .fontSize(13)
        .fontColor('#64748B')
        .lineHeight(18)
        .maxLines(2)
    }
    .width(226)
    .padding(12)
    .backgroundColor('#F8FAFC')
    .border({ width: 1, color: '#E2E8F0' })
    .borderRadius(8)
  }

  /**
   * 卡片类型 → 卡片名称标签。
   *
   * 口径必须与 `pages/ChatMain.getCardLabel` **完全一致**：一律用页面标题
   * （今日学习建议 / 学情画像 / 学习搭子 / 今日任务 / 错题诊断），
   * 否则同一张卡在对话页和浮标气泡里会有两个名字。
   *
   * 原缺陷：这里只特判了 weakness / partner，而且 weakness 返回的是「错题诊断」——
   *   · 错题诊断卡（wrong）与今日任务卡（tasks）都落到默认分支显示「学习建议」，
   *     与卡片标题（如「今日任务」）自相矛盾；
   *   · 同一张 weakness 卡在对话页写「学情画像」、在浮标里写「错题诊断」，两边打架。
   */
  private getCardLabel(card: ChatCard): string {
    if (card.type === 'weakness') {
      return '学情画像';
    }
    if (card.type === 'partner') {
      return '学习搭子';
    }
    if (card.type === 'tasks') {
      return '今日任务';
    }
    if (card.type === 'wrong') {
      return '错题诊断';
    }
    return '今日学习建议';
  }
}
