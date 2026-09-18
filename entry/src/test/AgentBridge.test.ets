import { describe, it, expect } from '@ohos/hypium';
import { AgentBridge } from '../main/ets/services/AgentBridge';
import { AgentApiClient, ApiClientConfig } from '../main/ets/api/AgentApiClient';
import { ChatNavigation } from '../main/ets/services/ChatNavigation';
import { ChatMessage } from '../main/ets/models/ChatModels';
import { appState } from '../main/ets/data/AppState';

export default function agentBridgeTest() {
  describe('agentBridgeTest', () => {
    it('matches study intents from natural Chinese wording', 0, () => {
      expect(AgentBridge.matchIntentLocal('今天先学什么比较合适')).assertEqual('get_suggestion');
      expect(AgentBridge.matchIntentLocal('帮我看看错题薄弱点')).assertEqual('analyze_wrong');
      expect(AgentBridge.matchIntentLocal('给我匹配学习搭子')).assertEqual('match_partner');
      expect(AgentBridge.matchIntentLocal('随便聊两句')).assertEqual('get_suggestion');
    });

    it('builds the future backend request shape with trimmed history', 0, () => {
      const history: ChatMessage[] = [];
      for (let index: number = 0; index < 24; index++) {
        history.push({
          id: `m-${index}`,
          role: index % 2 === 0 ? 'user' : 'agent',
          text: `message-${index}`,
          time: '09:00',
          status: 'done'
        });
      }

      const request = AgentBridge.buildRequest('看看我的复习计划', 'image://wrong-question', history);
      expect(request.message).assertEqual('看看我的复习计划');
      expect(request.image).assertEqual('image://wrong-question');
      expect(request.history.length).assertEqual(20);
      expect(request.history[0].text).assertEqual('message-4');
    });

    it('returns cards that map to the three A-side entry points', 0, async () => {
      const original: ApiClientConfig = AgentApiClient.getConfig();
      AgentApiClient.configure({ baseUrl: original.baseUrl, useFixture: true, timeoutMs: original.timeoutMs });
      const suggestion = await AgentBridge.callAgent('今天学习建议', undefined, []);
      const weakness = await AgentBridge.callAgent('分析错题薄弱点', 'image://wrong-question', []);
      const partner = await AgentBridge.callAgent('匹配搭子', undefined, []);
      AgentApiClient.configure(original);

      expect(suggestion.card?.type).assertEqual('tasks');
      expect(suggestion.card?.targetPage).assertEqual('pages/StudyPlan');
      expect(suggestion.reply.indexOf('LLM') === -1).assertTrue();
      expect(weakness.card?.type).assertEqual('wrong');
      expect(weakness.card?.targetPage).assertEqual('pages/WrongQuestion');
      expect(partner.card?.type).assertEqual('partner');
      expect(partner.card?.targetPage).assertEqual('pages/PartnerMatch');
    });

    it('returns a completed workbench task to the chat with a next step', 0, () => {
      appState.completeChatTask('错题已加入明日复习。', '现在可以确认本周复习计划。', '复习计划', 'pages/StudyPlan');
      const handoff = appState.consumeChatHandoff();

      expect(handoff?.summary).assertEqual('错题已加入明日复习。');
      expect(handoff?.nextPrompt).assertEqual('现在可以确认本周复习计划。');
      expect(handoff?.actionLabel).assertEqual('复习计划');
      expect(handoff?.targetPage).assertEqual('pages/StudyPlan');
      expect(appState.consumeChatHandoff()).assertNull();
    });

    it('keeps backend cards inside registered application routes', 0, () => {
      const card = AgentBridge.parseCard({
        'type': 'weakness',
        'title': '知识画像',
        'summary': '查看薄弱点',
        'targetPage': 'pages/NotRegistered'
      });
      expect(card.type).assertEqual('weakness');
      expect(card.targetPage).assertEqual('pages/StudyTags');
      expect(card.actions?.[0].targetPage).assertEqual('pages/StudyTags');

      const unknownTypeCard = AgentBridge.parseCard({
        'type': 'unknown',
        'title': '未知卡片',
        'summary': '',
        'targetPage': 'https://example.invalid'
      });
      expect(unknownTypeCard.type).assertEqual('suggestion');
      expect(unknownTypeCard.targetPage).assertEqual('pages/StudySuggestion');
    });

    it('normalizes v0.3 backend intent cards to frontend routes', 0, () => {
      const wrongCard = AgentBridge.parseCard({
        'type': 'analyze_wrong',
        'title': '错题分析',
        'actionLabel': '查看错题并开始分析',
        'targetPage': 'pages/WrongQuestions'
      });
      const partnerCard = AgentBridge.parseCard({
        'type': 'match_partner',
        'title': '学习搭子',
        'actionLabel': '查找合适的学习伙伴',
        'targetPage': 'pages/Partner'
      });
      const tasksCard = AgentBridge.parseCard({
        'type': 'query_tasks',
        'title': '今日任务',
        'actionLabel': '查看待完成的学习任务',
        'targetPage': 'pages/Tasks'
      });

      expect(wrongCard.type).assertEqual('wrong');
      expect(wrongCard.targetPage).assertEqual('pages/WrongQuestion');
      expect(wrongCard.actions?.[0].label).assertEqual('查看错题并开始分析');
      expect(partnerCard.type).assertEqual('partner');
      expect(partnerCard.targetPage).assertEqual('pages/PartnerMatch');
      expect(tasksCard.type).assertEqual('tasks');
      expect(tasksCard.targetPage).assertEqual('pages/StudyPlan');
    });

    it('rejects malformed backend response fields before rendering', 0, () => {
      let invalidReplyRejected: boolean = false;
      let invalidCardRejected: boolean = false;
      try {
        AgentBridge.parseResponse({ 'reply': 200, 'intent': 'get_suggestion' });
      } catch (error) {
        invalidReplyRejected = true;
      }
      try {
        AgentBridge.parseResponse({
          'reply': '已生成建议',
          'intent': 'get_suggestion',
          'card': ['not-a-card']
        });
      } catch (error) {
        invalidCardRejected = true;
      }

      expect(invalidReplyRejected).assertTrue();
      expect(invalidCardRejected).assertTrue();
    });

    it('uses the chat home as the fixed return destination', 0, () => {
      expect(ChatNavigation.chatHome()).assertEqual('pages/ChatMain');
    });
  });
}
