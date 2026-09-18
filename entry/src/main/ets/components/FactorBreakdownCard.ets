import { DecisionFactor } from '../api/ApiModels';

@Component
export struct FactorBreakdownCard {
  @Prop factors: DecisionFactor[];
  @Prop reason: string;
  @State expanded: boolean = false;

  private factorName(name: string): string {
    if (name === '1-Mastery') return '1 − 掌握度';
    if (name === 'ErrorIntensity') return '错误强度';
    if (name === 'Importance') return '课程重要性';
    if (name === 'Urgency') return '时间紧迫度';
    if (name === 'PrerequisiteImpact') return '先修影响';
    return name;
  }

  private totalContribution(): number {
    let total: number = 0;
    for (let index: number = 0; index < this.factors.length; index++) {
      total += this.factors[index].contribution;
    }
    return total;
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Text('Agent 的判断依据').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1F2937')
        Blank()
        Text(this.expanded ? '收起 ↑' : '展开 ↓').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#2563EB')
      }.width('100%').onClick(() => this.expanded = !this.expanded)
      if (this.expanded) {
        ForEach(this.factors, (factor: DecisionFactor) => {
          Row() {
            Text(this.factorName(factor.name)).fontSize(13).fontColor('#475467').layoutWeight(1)
            Text(`${factor.value.toFixed(2)} × ${factor.weight.toFixed(2)} = ${factor.contribution.toFixed(3)}`)
              .fontSize(12).fontColor('#2563EB')
          }.width('100%')
        }, (factor: DecisionFactor) => factor.name)
        Row() {
          Text('综合优先级').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#1F2937')
          Blank()
          Text(this.totalContribution().toFixed(2)).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F766E')
        }.width('100%').padding({ top: 8 }).border({ width: { top: 1 }, color: '#E2E8F0' })
        Text(`结论：${this.reason}`).fontSize(13).fontColor('#475467').lineHeight(20).width('100%')
      } else {
        Text('展开查看各因子的数值、权重与贡献。').fontSize(12).fontColor('#667085').width('100%')
      }
    }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(14)
      .border({ width: 1, color: '#BFDBFE' })
  }
}
