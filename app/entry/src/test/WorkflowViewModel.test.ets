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
  });
}
