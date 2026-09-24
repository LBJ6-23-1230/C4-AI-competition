import { describe, it, expect } from '@ohos/hypium';
import { LocalAgentService } from '../main/ets/services/LocalAgentService';
import { AppState } from '../main/ets/data/AppState';
import { FocusSession, LearningBadge, LearningPlanTask, WeeklyLearningPlan } from '../main/ets/models/AgentModels';

export default function focusLogicTest() {
  describe('focusLogicTest', () => {
    it('breaks a low-completion task into a shorter next step', 0, () => {
      const feedback = LocalAgentService.createFocusFeedback({
        taskId: 'focus-1', course: '数据结构', task: '梳理二叉树中序遍历',
        plannedMinutes: 30, actualMinutes: 12, pauseCount: 1,
        interruptionCount: 0, completionRate: 40, selfAssessment: 'partial',
        timerType: 'countdown', status: 'not_completed',
        endedAt: '2026-07-14 21:12'
      });
      expect(feedback.level).assertEqual('adjust');
      expect(feedback.nextSuggestion).assertContain('15 分钟');
    });

    it('recommends consolidation after a completed focus session', 0, () => {
      const feedback = LocalAgentService.createFocusFeedback({
        taskId: 'focus-2', course: '数据结构', task: '完成二叉树遍历练习',
        plannedMinutes: 30, actualMinutes: 30, pauseCount: 0,
        interruptionCount: 0, completionRate: 100, selfAssessment: 'completed',
        timerType: 'countdown', status: 'completed',
        endedAt: '2026-07-14 21:30'
      });
      expect(feedback.level).assertEqual('advance');
      expect(feedback.nextSuggestion).assertContain('巩固');
    });
    it('treats strict interruptions as an adjustment session', 0, () => {
      const feedback = LocalAgentService.createFocusFeedback({
        taskId: 'focus-strict-1', course: 'Data Structure', task: 'Review binary tree traversal',
        plannedMinutes: 30, actualMinutes: 8, pauseCount: 0,
        interruptionCount: 1, completionRate: 27, selfAssessment: 'not_completed',
        timerType: 'countdown', status: 'interrupted',
        endedAt: '2026-07-15 20:10'
      });
      expect(feedback.level).assertEqual('adjust');
      expect(feedback.nextSuggestion).assertContain('15');
    });

    it('supports stopwatch sessions without a planned target', 0, () => {
      const feedback = LocalAgentService.createFocusFeedback({
        taskId: 'focus-stopwatch-1', course: 'Operating System', task: 'Read process scheduling notes',
        plannedMinutes: 0, actualMinutes: 18, pauseCount: 0,
        interruptionCount: 0, completionRate: 100, selfAssessment: 'completed',
        timerType: 'stopwatch', status: 'completed',
        endedAt: '2026-07-15 20:35'
      });
      expect(feedback.level).assertEqual('advance');
    });

    it('updates the exact plan task carried by the focus session', 0, () => {
      const task: LearningPlanTask = {
        id: 'plan-task-1', course: '数据结构', title: '同名任务', knowledgePoint: '二叉树遍历',
        type: 'review', dateLabel: '今天', plannedMinutes: 30, priorityScore: 90,
        priorityLabel: '高优先级', reason: '测试', completionCriteria: '完成', steps: ['开始'],
        status: 'in_progress', source: 'agent', canCollaborate: false
      };
      const otherTask: LearningPlanTask = {
        id: 'plan-task-2', course: '数据结构', title: '同名任务', knowledgePoint: '图遍历',
        type: 'review', dateLabel: '今天', plannedMinutes: 30, priorityScore: 80,
        priorityLabel: '高优先级', reason: '测试', completionCriteria: '完成', steps: ['开始'],
        status: 'todo', source: 'agent', canCollaborate: false
      };
      const plan: WeeklyLearningPlan = {
        weekLabel: '本周', tasks: [otherTask, task],
        decisionTrace: { inputSummary: '', urgencyReason: '', weaknessReason: '', timeReason: '', recommendation: '', updatedAt: '' },
        adjustmentMessage: ''
      };
      const session: FocusSession = {
        taskId: 'focus-plan-1', planTaskId: 'plan-task-1', course: '数据结构', task: '同名任务',
        plannedMinutes: 30, actualMinutes: 30, pauseCount: 0, interruptionCount: 0,
        completionRate: 100, selfAssessment: 'completed', timerType: 'countdown', status: 'completed', endedAt: '现在'
      };

      LocalAgentService.adjustPlanAfterFocus(plan, session);
      expect(plan.tasks[0].status).assertEqual('todo');
      expect(plan.tasks[1].status).assertEqual('completed');
    });

    it('saves a focus session only once', 0, () => {
      const state: AppState = AppState.getInstance();
      state.focusSessions = [];
      const session: FocusSession = {
        taskId: 'focus-once', course: '数据结构', task: '复习', plannedMinutes: 30, actualMinutes: 20,
        pauseCount: 0, interruptionCount: 0, completionRate: 67, selfAssessment: 'partial',
        timerType: 'countdown', status: 'not_completed', endedAt: '现在'
      };

      expect(state.saveFocusSession(session)).assertTrue();
      expect(state.saveFocusSession(session)).assertFalse();
      expect(state.focusSessions.length).assertEqual(1);
    });

    it('does not award focus badges without focus time', 0, () => {
      const state: AppState = AppState.getInstance();
      state.focusSessions = [];
      state.weeklyPlan = null;
      const review = LocalAgentService.generateReviewSummary(null, null, null);
      expect(review.totalMinutes).assertEqual(0);
      expect(review.badges.some((badge: LearningBadge) => badge.name === '专注达人')).assertFalse();
    });
  });
}
