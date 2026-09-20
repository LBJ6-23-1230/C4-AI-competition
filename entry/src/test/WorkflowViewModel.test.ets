import { describe, it, expect } from '@ohos/hypium';
import { WorkflowStatusResponse } from '../main/ets/api/ApiModels';
import { WorkflowViewModel } from '../main/ets/viewmodels/WorkflowViewModel';

export default function workflowViewModelTest() {
  describe('workflowViewModelTest', () => {
    it('detects the exercise handoff as awaiting user answers', 0, () => {
      const status: WorkflowStatusResponse = {
        status: 'running',
        currentAgent: 'exercise',
        stateVersion: 2,
        finalAction: '提交答案后继续评估'
      };
      expect(WorkflowViewModel.isAwaitingAnswers(status)).assertTrue();
    });

    it('does not treat a completed workflow as awaiting user answers', 0, () => {
      const status: WorkflowStatusResponse = {
        status: 'completed',
        currentAgent: 'finish',
        stateVersion: 4,
        finalAction: '学习流程已完成'
      };
      expect(WorkflowViewModel.isAwaitingAnswers(status)).assertFalse();
    });

    it('does not treat an error state as awaiting user answers', 0, () => {
      const status: WorkflowStatusResponse = {
        status: 'error',
        currentAgent: 'exercise',
        stateVersion: 3,
        finalAction: null
      };
      expect(WorkflowViewModel.isAwaitingAnswers(status)).assertFalse();
    });
  });
}
