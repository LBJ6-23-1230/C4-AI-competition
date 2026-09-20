import { insightIntent, InsightIntentEntry, InsightIntentEntryExecutor } from '@kit.AbilityKit';

@InsightIntentEntry({
  intentName: 'QueryTodayStudyPlan',
  domain: 'Education',
  intentVersion: '1.0.0',
  displayName: '查看今日学习计划',
  displayDescription: '打开知学 Mate 的当前学习计划',
  llmDescription: '当用户询问今天学什么、今日任务或学习计划时使用',
  keywords: ['今日计划', '学习计划', '今天学什么', '今日任务'],
  abilityName: 'EntryAbility',
  executeMode: [insightIntent.ExecuteMode.UI_ABILITY_FOREGROUND]
})
export default class QueryTodayPlanIntent extends InsightIntentEntryExecutor<string> {
  async onExecute(): Promise<insightIntent.IntentResult<string>> {
    if (this.windowStage === undefined) {
      return { code: 1, result: '当前无法打开学习计划' };
    }
    try {
      await this.windowStage.loadContent('pages/StudyPlan');
      return { code: 0, result: '已打开今日学习计划' };
    } catch (error) {
      return { code: 1, result: '打开学习计划失败' };
    }
  }
}
