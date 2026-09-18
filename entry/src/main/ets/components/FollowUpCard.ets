import router from '@ohos.router';

/**
 * FollowUpCard —— 统一收口「下一步该做什么」。
 *
 * 为什么需要这个组件
 * ------------------
 * 原版 App 最大的问题不是功能少，而是**每个页面都在展示数据，却不告诉用户下一步**：
 * 做完练习只看到分数、写完错题只看到分析、看完画像只看到雷达图，
 * 然后就没有然后了 —— 用户必须自己回首页猜。
 *
 * 但 Agent 的设计初衷（docs/前端README.md 的 5 层工作流）恰恰是：
 *   **第 4 层「行动层」与第 5 层「输出层」要把判断转成可执行的下一步。**
 * 这个组件就是把第 5 层落到界面上：**每个终点页都必须给出一个明确的下一跳。**
 *
 * 三条使用纪律
 * ------------
 * 1. **一个页面只用一次**，放在内容流末尾，作为"然后呢？"的唯一答案；
 * 2. `primaryText` 是**唯一**实心按钮，其余最多一个描边按钮
 *    （遵循项目设计规范「每页只有一个实心主按钮」）；
 * 3. 文案必须是**具体动作**，不是"查看详情"这类空泛词
 *    （例如「做 3 道二叉树专项题」而不是「去练习」）。
 */
@Component
export struct FollowUpCard {
  /** 卡片标题，例如「接下来」。 */
  @Prop title: string = '接下来';
  /** 一句话说明为什么建议这一步（来自 Agent 的判断，不硬编码）。 */
  @Prop reason: string = '';
  /** 主行动文案。空串表示不显示主按钮。 */
  @Prop primaryText: string = '';
  /** 主行动目标页。 */
  @Prop primaryTarget: string = '';
  /** 次要行动文案。 */
  @Prop secondaryText: string = '';
  /** 次要行动目标页。 */
  @Prop secondaryTarget: string = '';
  /** 是否显示「看 Agent 决策过程」入口。 */
  @Prop showAgentTraceLink: boolean = false;

  /** 自定义主行动（优先于 primaryTarget）。用于需要先写状态再跳转的场景。 */
  onPrimary?: () => void;
  onSecondary?: () => void;

  private go(target: string): void {
    if (target.length === 0) {
      return;
    }
    router.pushUrl({ url: target });
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('◎').fontSize(15).fontColor('#2563EB')
        Text(this.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1F2937')
        Blank()
      }.width('100%')

      if (this.reason.length > 0) {
        Text(this.reason)
          .fontSize(13).fontColor('#475467').lineHeight(20).width('100%')
      }

      if (this.primaryText.length > 0) {
        Button(this.primaryText)
          .width('100%').height(48).fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(12)
          .onClick(() => {
            if (this.onPrimary !== undefined) {
              this.onPrimary();
            } else {
              this.go(this.primaryTarget);
            }
          })
      }

      if (this.secondaryText.length > 0) {
        Button(this.secondaryText)
          .width('100%').height(44).fontSize(14).fontColor('#2563EB')
          .backgroundColor('#FFFFFF').border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
          .onClick(() => {
            if (this.onSecondary !== undefined) {
              this.onSecondary();
            } else {
              this.go(this.secondaryTarget);
            }
          })
      }

      if (this.showAgentTraceLink) {
        Row({ space: 4 }) {
          Text('想知道它为什么这么安排？').fontSize(12).fontColor('#667085')
          Text('看 Agent 决策过程 →').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#2563EB')
        }
        .width('100%')
        .onClick(() => this.go('pages/AgentTrace'))
      }
    }
    .width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
    .border({ width: 1, color: '#BFDBFE' })
  }
}
