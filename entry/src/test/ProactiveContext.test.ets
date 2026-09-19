import { describe, it, expect } from '@ohos/hypium';
import { ClientCache } from '../main/ets/cache/ClientCache';
import { ProactiveRequest } from '../main/ets/api/ApiModels';
import { ProactiveViewModel } from '../main/ets/viewmodels/ProactiveViewModel';

export default function proactiveContextTest() {
  describe('proactiveContextTest', () => {
    it('does not invent optional learning context when no profile is cached', 0, () => {
      ClientCache.invalidateProfile();
      const request: ProactiveRequest = ProactiveViewModel.buildRequest(
        'demo-user', 5, true, false, '2026-09-18T12:00:00Z');

      expect(request.context.foreground).assertTrue();
      expect(request.context.focusSessionActive).assertFalse();
      expect(request.context.daysLeft).assertEqual(5);
      expect(request.context.lastStudyAt).assertEqual('2026-09-18T12:00:00Z');
      expect(request.context.masteryScore === undefined).assertTrue();
      expect(request.context.errorIntensity === undefined).assertTrue();
      expect(request.context.importance === undefined).assertTrue();
      expect(request.context.pendingTasks !== undefined).assertTrue();
      expect(request.context.pendingTasks?.length).assertEqual(4);
      expect(request.context.pendingTasks?.[0].daysLeft).assertEqual(2);
      expect(request.context.pendingTasks?.[0].started).assertFalse();
    });

    it('uses the weakest cached mastery instead of a fixed demo score', 0, () => {
      ClientCache.cacheProfile({
        profileVersion: 2,
        mastery: [
          { knowledgePointId: 'a', knowledgePointName: 'A', masteryScore: 72,
            confidence: 0.9, lastUpdated: '2026-09-18T10:00:00Z' },
          { knowledgePointId: 'b', knowledgePointName: 'B', masteryScore: 41,
            confidence: 0.8, lastUpdated: '2026-09-18T11:00:00Z' }
        ],
        history: [],
        evidence: []
      });

      const request: ProactiveRequest = ProactiveViewModel.buildRequest('user-1', -2, false, true);
      expect(request.context.masteryScore).assertEqual(41);
      expect(request.context.daysLeft).assertEqual(0);
      expect(request.context.focusSessionActive).assertTrue();
      ClientCache.invalidateProfile();
    });
  });
}
