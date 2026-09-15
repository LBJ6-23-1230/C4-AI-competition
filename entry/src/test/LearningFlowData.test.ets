import { describe, it, expect } from '@ohos/hypium';
import { learningFlowPages } from '../main/ets/models/LearningFlowData';

export default function learningFlowDataTest() {
  describe('learningFlowDataTest', () => {
    it('keeps the archived eight-step demo flow in order', 0, () => {
      expect(learningFlowPages.length).assertEqual(8);
      expect(learningFlowPages[0].title).assertEqual('课程感知 Agent');
      expect(learningFlowPages[1].title).assertEqual('Agent 仪表盘');
      expect(learningFlowPages[2].title).assertEqual('今日学习建议');
      expect(learningFlowPages[3].title).assertEqual('错题理解 Agent');
      expect(learningFlowPages[4].title).assertEqual('知识薄弱卡');
      expect(learningFlowPages[5].title).assertEqual('伙伴匹配 Agent');
      expect(learningFlowPages[6].title).assertEqual('学习协同空间');
      expect(learningFlowPages[7].title).assertEqual('学习复盘');
    });

    it('keeps the archived flow actions and destinations aligned', 0, () => {
      expect(learningFlowPages[0].primaryAction).assertEqual('进入首页');
      expect(learningFlowPages[0].nextUrl).assertEqual('pages/Index');
      expect(learningFlowPages[1].primaryAction).assertEqual('查看今日建议');
      expect(learningFlowPages[1].nextUrl).assertEqual('pages/StudySuggestion');
      expect(learningFlowPages[6].primaryAction).assertEqual('完成学习 · 查看复盘');
      expect(learningFlowPages[6].nextUrl).assertEqual('pages/ReviewSummary');
      expect(learningFlowPages[7].primaryAction).assertEqual('返回首页');
      expect(learningFlowPages[7].nextUrl).assertEqual('pages/Index');
    });

    it('contains the archived course and agent scenario details', 0, () => {
      expect(learningFlowPages[0].cards[0].title).assertContain('3 门课程');
      expect(learningFlowPages[0].cards[0].bullets.length).assertEqual(3);
      expect(learningFlowPages[1].cards[0].title).assertContain('小知');
      expect(learningFlowPages[1].cards[0].bullets[1]).assertContain('二叉树遍历');
    });
  });
}
