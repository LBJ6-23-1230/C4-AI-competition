import { describe, it, expect } from '@ohos/hypium';
import { AppState } from '../main/ets/data/AppState';
import { mockCandidates, mockCurrentUser } from '../main/ets/data/MockData';
import { LocalAgentService } from '../main/ets/services/LocalAgentService';
import { LearningPlanTask, PartnerMatch } from '../main/ets/models/AgentModels';

export default function partnerFlowTest() {
  describe('partnerFlowTest', () => {
    it('creates one executable collaborative task for the best partner', 0, () => {
      const partner: PartnerMatch | null = LocalAgentService.matchBestPartner(mockCurrentUser, mockCandidates);
      expect(partner === null).assertFalse();
      if (partner === null) {
        return;
      }
      const task: LearningPlanTask = LocalAgentService.createCollaborativeTask(partner, mockCurrentUser);
      expect(task.source).assertEqual('partner_match');
      expect(task.canCollaborate).assertTrue();
      expect(task.plannedMinutes > 0).assertTrue();

      const state: AppState = AppState.getInstance();
      state.setWeeklyPlan(LocalAgentService.generateWeeklyPlan(state.courses, state.homeworkDDLs, state.currentUser));
      expect(state.addCollaborativeTask(task, '已安排')).assertTrue();
      expect(state.addCollaborativeTask(task, '再次安排')).assertFalse();
      expect(state.weeklyPlan?.tasks.filter((item: LearningPlanTask) => item.id === task.id).length).assertEqual(1);

      state.updatePlanTaskStatus(task.id, 'completed');
      expect(state.hasActiveCollaborativeTask(task.id)).assertFalse();
      expect(state.hasCompletedCollaborativeTask(task.id)).assertTrue();
      const nextTask: LearningPlanTask = LocalAgentService.createCollaborativeTask(partner, mockCurrentUser);
      nextTask.id = state.nextCollaborativeTaskId(nextTask.id);
      expect(nextTask.id === task.id).assertFalse();
      expect(state.addCollaborativeTask(nextTask, '开始新一轮协同')).assertTrue();
      expect(state.weeklyPlan?.tasks.filter((item: LearningPlanTask) => item.source === 'partner_match').length).assertEqual(2);
    });
  });
}
