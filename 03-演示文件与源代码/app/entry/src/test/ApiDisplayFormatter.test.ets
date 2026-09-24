import { describe, it, expect } from '@ohos/hypium';
import { ApiDisplayFormatter } from '../main/ets/utils/ApiDisplayFormatter';

export default function apiDisplayFormatterTest() {
  describe('apiDisplayFormatterTest', () => {
    it('localizes known workflow values without hiding unknown values', 0, () => {
      expect(ApiDisplayFormatter.workflowStatus('completed')).assertEqual('已完成');
      expect(ApiDisplayFormatter.agent('planner')).assertEqual('计划调整');
      expect(ApiDisplayFormatter.tool('update_mastery')).assertEqual('更新掌握度');
      expect(ApiDisplayFormatter.metric('customMetric')).assertEqual('customMetric');
    });

    it('renders the fixture knowledge point as a user label', 0, () => {
      expect(ApiDisplayFormatter.knowledgePoint('binary-tree-postorder')).assertEqual('二叉树后序遍历');
    });
  });
}
