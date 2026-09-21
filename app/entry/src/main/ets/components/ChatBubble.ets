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

  private getCardLabel(card: ChatCard): string {
    if (card.type === 'weakness') {
      return '错题诊断';
    }
    if (card.type === 'partner') {
      return '学习搭子';
    }
    return '学习建议';
  }
}
