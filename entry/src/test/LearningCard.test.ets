import { describe, it, expect } from '@ohos/hypium';
import { ProactiveResponse } from '../main/ets/api/ApiModels';
import { LearningCardData, LearningCardService } from '../main/ets/services/LearningCardService';

function decision(taskName?: string, presetMinutes?: number, cardMinutes?: number): ProactiveResponse {
  return {
    shouldNotify: false,
    channel: 'silent',
    title: '复习提醒',
    body: '完成今日复习',
    action: { type: 'focus', targetPage: 'pages/FocusSetup', preset: { durationMinutes: presetMinutes } },
    contextTags: [],
    reason: '考试临近且该知识点掌握度较低',
    factors: [],
    cardData: { taskName: taskName, durationMinutes: cardMinutes }
  };
}

export default function learningCardTest() {
  describe('learningCardTest', () => {
    it('maps the current Agent decision to service-card text', 0, () => {
      const data: LearningCardData = LearningCardService.fromDecision(decision('二叉树遍历', 25, 40));
      expect(data.taskName).assertEqual('二叉树遍历');
      expect(data.durationText).assertEqual('25 分钟');
      expect(data.durationMinutes).assertEqual(25);
      expect(data.reason).assertEqual('考试临近且该知识点掌握度较低');
    });

    it('uses response body and card duration as safe fallbacks', 0, () => {
      const data: LearningCardData = LearningCardService.fromDecision(decision(undefined, undefined, 15));
      expect(data.taskName).assertEqual('完成今日复习');
      expect(data.durationText).assertEqual('15 分钟');
      expect(data.durationMinutes).assertEqual(15);
      expect(data.actionText).assertEqual('开始专注');
    });
  });
}
