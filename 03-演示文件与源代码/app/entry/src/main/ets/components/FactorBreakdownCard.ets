import { DecisionFactor } from '../api/ApiModels';

@Component
export struct FactorBreakdownCard {
  @Prop factors: DecisionFactor[];
  @Prop reason: string;
  @State expanded: boolean = false;

  /**
   * 因子名 → 中文。
   *
   * ⚠️ 必须同时认**两种拼法**：两个后端路径给出的因子名不一致 ——
   *   · `/api/v1/agent/proactive` 给 `1-Mastery` / `ErrorIntensity` …（帕斯卡式）
   *   · `/api/v1/plans/current`   给 `mastery`  / `errorIntensity` …（小驼峰）
   * 原来只映射帕斯卡式，于是**在线模式下这个面板把英文原名直接显示给用户**
   * （实测反馈：「有的东西不要写给用户直接看」）。
   * 认不出来的仍然原样返回，不编造。
   */
  private factorName(name: string): string {
    if (name === '1-Mastery' || name === 'mastery') return '1 − 掌握度';
    if (name === 'ErrorIntensity' || name === 'errorIntensity') return '错误强度';
    if (name === 'Importance' || name === 'importance') return '课程重要性';
    if (name === 'Urgency' || name === 'urgency') return '时间紧迫度';
    if (name === 'PrerequisiteImpact' || name === 'prerequisiteImpact') return '先修影响';
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
      // 标题去「元信息味」：不写"Agent 的判断依据"（那是在讲我的思考过程），
      // 而是用户真正会问的那句话 —— "为什么是它"。
      Row() {
        Text('为什么是它').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#1F2937')
        Blank()
        Text(this.expanded ? '收起 ↑' : '展开 ↓').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#2563EB')
      }.width('100%').onClick(() => this.expanded = !this.expanded)

      // 折叠态**结论先行**：先说人话（Agent 已经想清楚了），
      // 算式留在展开后（给想深究的用户与评委审计用）。
      // 原文案"展开查看各因子的数值、权重与贡献"是说明书语气，等于什么都没说。
      if (!this.expanded) {
        Text(this.reason.length > 0 ? this.reason : '展开查看它为什么这样安排。')
          .fontSize(13).fontColor('#475467').lineHeight(20).width('100%')
      }

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
        if (this.reason.length > 0) {
          Text(`结论：${this.reason}`).fontSize(13).fontColor('#475467').lineHeight(20).width('100%')
        }
      }
    }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(14)
      .border({ width: 1, color: '#E2E8F0' })
  }
}
