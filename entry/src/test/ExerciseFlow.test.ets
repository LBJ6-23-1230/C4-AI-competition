import { describe, it, expect } from '@ohos/hypium';
import { AgentApiClient, ApiClientConfig } from '../main/ets/api/AgentApiClient';
import { ExerciseSetResponse, WorkflowResponse } from '../main/ets/api/ApiModels';
import { ClientCache } from '../main/ets/cache/ClientCache';
import { FixtureDemoStateStore } from '../main/ets/api/FixtureDemoStateStore';

export default function exerciseFlowTest() {
  describe('exerciseFlowTest', () => {
    it('uses the real backend by default and normalizes configured base urls', 0, () => {
      const original: ApiClientConfig = AgentApiClient.getConfig();
      expect(original.useFixture).assertFalse();
      expect(original.baseUrl).assertEqual('http://10.0.2.2:5000');

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

    it('keeps one workflow identity and clears its derived status together', 0, () => {
      const workflow: WorkflowResponse = {
        sessionId: 'session-test',
        traceId: 'trace-test',
        status: 'running',
        currentStep: 'diagnosis',
        nextAction: 'diagnose'
      };
      ClientCache.cacheWorkflow(workflow);
      ClientCache.cacheWorkflowStatus({
        status: 'running',
        currentAgent: 'diagnosis',
        stateVersion: 2,
        finalAction: null
      });
      expect(ClientCache.getWorkflow()?.traceId).assertEqual('trace-test');

      ClientCache.invalidateWorkflow();
      expect(ClientCache.getWorkflow()).assertNull();
      expect(ClientCache.getWorkflowStatus()).assertNull();
    });

    it('keeps the fixture profile plan and workflow status on one demo state', 0, async () => {
      const original: ApiClientConfig = AgentApiClient.getConfig();
      AgentApiClient.configure({ baseUrl: original.baseUrl, useFixture: true, timeoutMs: original.timeoutMs });
      FixtureDemoStateStore.reset();

      const initialProfile = await AgentApiClient.getProfile('demo-user');
      expect(initialProfile.ok).assertTrue();
      if (initialProfile.ok) {
        expect(initialProfile.data.profileVersion).assertEqual(1);
        expect(initialProfile.data.mastery[0].masteryScore).assertEqual(42);
      }

      await AgentApiClient.submitExercise('set-demo-binary-tree-001', {
        idempotencyKey: 'fixture-state-test',
        answers: []
      });
      const updatedProfile = await AgentApiClient.getProfile('demo-user');
      const updatedPlan = await AgentApiClient.getCurrentPlan();
      const updatedWorkflow = await AgentApiClient.getWorkflow('session-demo-001');
      expect(updatedProfile.ok).assertTrue();
      expect(updatedPlan.ok).assertTrue();
      expect(updatedWorkflow.ok).assertTrue();
      if (updatedProfile.ok && updatedPlan.ok && updatedWorkflow.ok) {
        expect(updatedProfile.data.profileVersion).assertEqual(2);
        expect(updatedProfile.data.mastery[0].masteryScore).assertEqual(58);
        expect(updatedPlan.data.version).assertEqual(2);
        expect(updatedWorkflow.data.stateVersion).assertEqual(5);
      }

      FixtureDemoStateStore.reset();
      AgentApiClient.configure(original);
    });
  });
}
