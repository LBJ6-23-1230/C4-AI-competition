import { describe, it, expect } from '@ohos/hypium';
import { AgentApiClient, ApiClientConfig } from '../main/ets/api/AgentApiClient';
import { ExerciseSetResponse } from '../main/ets/api/ApiModels';
import { ClientCache } from '../main/ets/cache/ClientCache';

export default function exerciseFlowTest() {
  describe('exerciseFlowTest', () => {
    it('uses the real backend by default and normalizes configured base urls', 0, () => {
      const original: ApiClientConfig = AgentApiClient.getConfig();
      expect(original.useFixture).assertFalse();

      AgentApiClient.configure({
        baseUrl: 'http://127.0.0.1:5000/',
        useFixture: true,
        timeoutMs: 1000
      });
      const configured: ApiClientConfig = AgentApiClient.getConfig();
      expect(configured.baseUrl).assertEqual('http://127.0.0.1:5000');
      expect(configured.useFixture).assertTrue();

      AgentApiClient.configure(original);
    });

    it('invalidates the exercise cache before a forced retry', 0, () => {
      const exerciseSet: ExerciseSetResponse = {
        setId: 'set-test',
        exercises: []
      };
      ClientCache.cacheExerciseSet(exerciseSet);
      expect(ClientCache.getExerciseSet()?.setId).assertEqual('set-test');

      ClientCache.invalidateExerciseSet();
      expect(ClientCache.getExerciseSet()).assertNull();
    });

    it('invalidates trace data after state-changing operations', 0, () => {
      ClientCache.cacheTrace({
        traceId: 'trace-stale',
        events: []
      });
      expect(ClientCache.getTrace()?.traceId).assertEqual('trace-stale');

      ClientCache.invalidateTrace();
      expect(ClientCache.getTrace()).assertNull();
    });
  });
}
