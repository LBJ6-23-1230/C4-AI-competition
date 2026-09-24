import { insightIntent, InsightIntentEntry, InsightIntentEntryExecutor } from '@kit.AbilityKit';
import { appState } from '../data/AppState';

@InsightIntentEntry({
  intentName: 'StartStudyFocus',
  domain: 'Education',
  intentVersion: '1.0.0',
  displayName: '开始学习专注',
  displayDescription: '为指定的学习任务打开专注设置页',
  llmDescription: '当用户想开始学习、复习某个科目或进入专注模式时使用',
  keywords: ['开始学习', '开始专注', '复习', '番茄钟'],
  abilityName: 'EntryAbility',
  executeMode: [insightIntent.ExecuteMode.UI_ABILITY_FOREGROUND],
  parameters: {
    '$schema': 'http://json-schema.org/draft-07/schema#',
    'type': 'object',
    'properties': {
      'taskName': {
        'type': 'string',
        'description': '用户想学习或复习的任务名称',
        'minLength': 1
      },
      'durationMinutes': {
        'type': 'number',
        'description': '计划专注的分钟数',
        'minimum': 1,
        'maximum': 180
      }
    }
  }
})
export default class StartFocusIntent extends InsightIntentEntryExecutor<string> {
  taskName: string = '';
  durationMinutes: number = 30;

  async onExecute(): Promise<insightIntent.IntentResult<string>> {
    const normalizedTask: string = this.taskName.trim();
    const normalizedDuration: number = this.durationMinutes >= 1 && this.durationMinutes <= 180 ?
      Math.round(this.durationMinutes) : 30;
    appState.setFocusTask({
      course: appState.getHighPriorityCourse().courseName,
      task: normalizedTask.length > 0 ? normalizedTask : '完成今日学习建议',
      plannedMinutes: normalizedDuration,
      source: 'agent',
      mode: 'normal',
      timerType: 'countdown'
    });
    if (this.windowStage === undefined) {
      return { code: 1, result: '当前无法打开专注设置' };
    }
    try {
      await this.windowStage.loadContent('pages/FocusSetup');
      return { code: 0, result: '已打开专注设置' };
    } catch (error) {
      return { code: 1, result: '打开专注设置失败' };
    }
  }
}
