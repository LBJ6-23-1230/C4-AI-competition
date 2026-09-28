import router from '@ohos.router';
import { AgentApiClient } from '../api/AgentApiClient';
import { WrongBookAttemptResponse, WrongBookCourse, WrongBookItem, WrongBookResponse } from '../api/ApiModels';

@Entry
@Component
struct WrongBook {
  @State isLoading: boolean = true;
  @State errorMessage: string = '';
  @State courses: WrongBookCourse[] = [];
  @State total: number = 0;
  @State practiceItem: WrongBookItem | null = null;
  @State selectedAnswer: string = '';
  @State attempt: WrongBookAttemptResponse | null = null;
  @State isSubmitting: boolean = false;
  @State practiceItems: WrongBookItem[] = [];
  @State practiceIndex: number = 0;

  aboutToAppear(): void { this.load(); }

  private async load(): Promise<void> {
    this.isLoading = true;
    const result = await AgentApiClient.getWrongBook();
    this.isLoading = false;
    if (!result.ok) {
      this.errorMessage = '错题本读取失败，请稍后重试。';
      return;
    }
    const data: WrongBookResponse = result.data;
    this.courses = data.courses;
    this.total = data.total;
  }

  private startPractice(item: WrongBookItem): void {
    const course: WrongBookCourse | undefined = this.courses.find((value: WrongBookCourse): boolean =>
      value.courseName === item.courseName);
    const items: WrongBookItem[] = course !== undefined ? course.items : [item];
    const startIndex: number = items.findIndex((value: WrongBookItem): boolean =>
      value.exerciseId === item.exerciseId);
    // 从用户点中的题开始，练到末尾后再接上前面的题，确保这一轮覆盖整个科目。
    this.practiceItems = startIndex > 0
      ? items.slice(startIndex).concat(items.slice(0, startIndex)) : items.slice();
    this.practiceIndex = 0;
    this.practiceItem = this.practiceItems[0];
    this.selectedAnswer = '';
    this.attempt = null;
  }

  private leavePractice(): void {
    this.practiceItem = null;
    this.practiceItems = [];
    this.practiceIndex = 0;
    this.selectedAnswer = '';
    this.attempt = null;
  }

  private continuePractice(): void {
    const nextIndex: number = this.practiceIndex + 1;
    if (nextIndex >= this.practiceItems.length) {
      this.leavePractice();
      return;
    }
    this.practiceIndex = nextIndex;
    this.practiceItem = this.practiceItems[nextIndex];
    this.selectedAnswer = '';
    this.attempt = null;
    this.errorMessage = '';
  }

  private async submitAttempt(): Promise<void> {
    if (this.practiceItem === null || this.selectedAnswer.length === 0 || this.isSubmitting) return;
    this.isSubmitting = true;
    const result = await AgentApiClient.attemptWrongBook(this.practiceItem.exerciseId, this.selectedAnswer);
    this.isSubmitting = false;
    if (!result.ok) {
      this.errorMessage = '本次作答提交失败，请重试。';
      return;
    }
    this.attempt = result.data;
    if (result.data.removed) await this.load();
  }

  private async removeItem(item: WrongBookItem): Promise<void> {
    const result = await AgentApiClient.toggleWrongBook(item.exerciseId, false);
    if (result.ok) {
      if (this.practiceItem?.exerciseId === item.exerciseId) this.practiceItem = null;
      await this.load();
    }
  }

  @Builder
  PracticePanel(item: WrongBookItem) {
    Column({ space: 12 }) {
      Row() {
        Text(`${item.courseName} · 第 ${this.practiceIndex + 1}/${this.practiceItems.length} 题`)
          .fontSize(13).fontColor('#2563EB')
        Blank()
        Text('返回题目列表').fontSize(13).fontColor('#64748B').onClick(() => this.leavePractice())
      }.width('100%')
      Text(item.stem).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#1F2937').lineHeight(24)
      ForEach(item.options, (option: string) => {
        Button(option).width('100%').height(42).fontSize(14)
          .fontColor(this.selectedAnswer === option.substring(0, 1) ? '#FFFFFF' : '#344054')
          .backgroundColor(this.selectedAnswer === option.substring(0, 1) ? '#2563EB' : '#F8FAFC')
          .border({ width: 1, color: '#D0D5DD' }).borderRadius(10)
          .enabled(this.attempt === null)
          .onClick(() => this.selectedAnswer = option.substring(0, 1))
      }, (option: string) => option)
      if (this.attempt !== null) {
        Text(this.attempt.correct ? '回答正确' : `回答错误，正确答案：${this.attempt.correctAnswer}`)
          .fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor(this.attempt.correct ? '#0F766E' : '#DC2626').width('100%')
        Text(this.attempt.explanation).fontSize(14).fontColor('#475467').lineHeight(21).width('100%')
        Text(this.attempt.removed ? '已累计答对 3 次，自动移出错题本。'
          : `已答对 ${this.attempt.correctCount} / 3 次。`)
          .fontSize(13).fontColor('#2563EB').width('100%')
        Button(this.practiceIndex + 1 < this.practiceItems.length ? '继续下一题' : '完成本学科刷题，返回列表')
          .width('100%').height(42).fontSize(14).fontColor('#FFFFFF')
          .backgroundColor('#2563EB').borderRadius(10)
          .onClick(() => this.continuePractice())
      } else {
        Button(this.isSubmitting ? '提交中…' : '提交答案').width('100%').height(44)
          .fontSize(15).fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(10)
          .enabled(this.selectedAnswer.length > 0 && !this.isSubmitting)
          .onClick(() => this.submitAttempt())
      }
    }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
      .border({ width: 1, color: '#BFDBFE' })
  }

  build() {
    Column() {
      Row() {
        Text(this.practiceItem !== null ? '← 题目列表' : '← 返回').fontSize(14).fontColor('#64748B')
          .onClick(() => this.practiceItem !== null ? this.leavePractice() : router.back())
        Blank()
        Text('错题本').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#111827')
        Blank()
        Text(`${this.total} 题`).fontSize(13).fontColor('#2563EB')
      }.width('100%').padding(16).backgroundColor('#FFFFFF')
      Scroll() {
        Column({ space: 14 }) {
          Text('按课程整理；在这里刷对同一道题 3 次后，系统会自动移出。')
            .fontSize(13).fontColor('#667085').lineHeight(20).width('100%')
          if (this.isLoading) {
            LoadingProgress().width(34).height(34).margin({ top: 48 })
          } else if (this.errorMessage.length > 0) {
            Text(this.errorMessage).fontSize(14).fontColor('#B42318')
          } else if (this.practiceItem !== null) {
            // 最后一题答对并被自动移除后 total 会立刻变成 0，仍要保留本题反馈与
            // “完成本学科”按钮；用户主动返回列表后再展示空状态。
            this.PracticePanel(this.practiceItem)
          } else if (this.total === 0) {
            Column({ space: 10 }) {
              Text('错题本还是空的').fontSize(18).fontWeight(FontWeight.Bold)
              Text('练习中答错的题会自动出现在这里，也可以在逐题解析页手动添加。')
                .fontSize(13).fontColor('#667085').lineHeight(20).textAlign(TextAlign.Center)
            }.width('100%').padding(32).alignItems(HorizontalAlign.Center)
          } else {
            ForEach(this.courses, (course: WrongBookCourse) => {
              Column({ space: 10 }) {
                Text(`${course.courseName}（${course.items.length}）`).fontSize(17)
                  .fontWeight(FontWeight.Bold).fontColor('#0F172A').width('100%')
                ForEach(course.items, (item: WrongBookItem) => {
                  Column({ space: 8 }) {
                    Text(item.stem).fontSize(14).fontColor('#1F2937').maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                    Row() {
                      Text(`${item.knowledgePointName} · 已答对 ${item.correctCount}/3`)
                        .fontSize(12).fontColor('#667085').layoutWeight(1)
                      Text('刷题').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#2563EB')
                        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                        .onClick(() => this.startPractice(item))
                      Text('移除').fontSize(13).fontColor('#B42318')
                        .padding({ left: 10, top: 5, bottom: 5 }).onClick(() => this.removeItem(item))
                    }.width('100%')
                  }.width('100%').padding(14).backgroundColor('#F8FAFC').borderRadius(12)
                }, (item: WrongBookItem) => item.exerciseId)
              }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
            }, (course: WrongBookCourse) => course.courseName)
          }
        }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 40 })
      }.layoutWeight(1).backgroundColor('#F3F6FA')
    }.width('100%').height('100%')
  }
}
