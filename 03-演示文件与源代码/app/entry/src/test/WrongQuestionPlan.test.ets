import { describe, it, expect } from '@ohos/hypium';
import { AppState } from '../main/ets/data/AppState';
import { LearningPlanTask, WeeklyLearningPlan } from '../main/ets/models/AgentModels';

function reviewTask(id: string): LearningPlanTask {
  return {
    id: id,
    course: '数据结构',
    title: '复习：二叉树遍历',
    knowledgePoint: '二叉树遍历',
    type: 'review',
    dateLabel: '9月13日 周日',
    plannedMinutes: 25,
    priorityScore: 92,
    priorityLabel: '高优先级',
    reason: '错题分析后复习',
    completionCriteria: '完成两道同类题',
    steps: ['回看错误原因', '完成同类题'],
    status: 'todo',
    source: 'wrong_question',
    canCollaborate: true
  };
}

function emptyPlan(): WeeklyLearningPlan {
  return {
    weekLabel: '本周学习计划',
    tasks: [],
    decisionTrace: {
      inputSummary: '', urgencyReason: '', weaknessReason: '', timeReason: '', recommendation: '', updatedAt: ''
    },
    adjustmentMessage: ''
  };
}

export default function wrongQuestionPlanTest() {
  describe('wrongQuestionPlanTest', () => {
    it('does not add the same pending wrong-question review twice', 0, () => {
      const state: AppState = AppState.getInstance();
      state.setWeeklyPlan(emptyPlan());

      expect(state.addReviewTask(reviewTask('wrong-1'), '已加入')).assertTrue();
      expect(state.addReviewTask(reviewTask('wrong-2'), '已加入')).assertFalse();
      expect(state.weeklyPlan?.tasks.length).assertEqual(1);
      expect(state.weeklyPlan?.adjustmentMessage).assertContain('无需重复添加');
    });

    it('allows a new review after the previous task is completed', 0, () => {
      const state: AppState = AppState.getInstance();
      state.setWeeklyPlan(emptyPlan());
      state.addReviewTask(reviewTask('wrong-1'), '已加入');
      state.updatePlanTaskStatus('wrong-1', 'completed');

      expect(state.addReviewTask(reviewTask('wrong-2'), '再次加入')).assertTrue();
      expect(state.weeklyPlan?.tasks.length).assertEqual(2);
    });

    it('clears only the active wrong-question draft', 0, () => {
      const state: AppState = AppState.getInstance();
      state.selectedImageUri = 'mock.jpg';
      state.latestWrongAnalysis = {
        course: '数据结构', knowledge: ['二叉树遍历'], wrongType: '概念混淆',
        reason: '测试', suggestions: ['复习'], tags: ['待巩固'], imageUri: 'mock.jpg'
      };

      state.clearCurrentWrongQuestionDraft();
      expect(state.selectedImageUri).assertEqual('');
      expect(state.latestWrongAnalysis).assertNull();
    });
  });
}
