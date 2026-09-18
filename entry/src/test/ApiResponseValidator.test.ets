import { describe, it, expect } from '@ohos/hypium';
import { ApiResponseValidator } from '../main/ets/api/ApiResponseValidator';
import { AgentApiClient } from '../main/ets/api/AgentApiClient';
import { ProactiveResponse, WorkflowRunResponse } from '../main/ets/api/ApiModels';

export default function apiResponseValidatorTest() {
  describe('apiResponseValidatorTest', () => {
    it('accepts contract-shaped payloads and rejects misleading JSON', 0, () => {
      const validPlan: Record<string, Object> = {
        'planId': 'plan-demo-001',
        'version': 2,
        'generatedFromProfileVersion': 2,
        'tasks': []
      };
      const malformedPlan: Record<string, Object> = {
        'planId': 'plan-demo-001',
        'version': '2',
        'generatedFromProfileVersion': 2,
        'tasks': []
      };
      const malformedProfile: Record<string, Object> = {
        'profileVersion': 2,
        'mastery': 'not-an-array',
        'history': [],
        'evidence': []
      };

      expect(ApiResponseValidator.isValid('GET', '/api/v1/plans/current', validPlan)).assertTrue();
      expect(ApiResponseValidator.isValid('GET', '/api/v1/plans/current', malformedPlan)).assertFalse();
      expect(ApiResponseValidator.isValid('GET', '/api/v1/profile/demo-user', malformedProfile)).assertFalse();
      expect(ApiResponseValidator.isValid('GET', '/api/v1/unknown', validPlan)).assertFalse();

      const workflowRun: WorkflowRunResponse = {
        sessionId: 'session-1',
        traceId: 'trace-session-1',
        status: 'completed',
        currentStep: 'finish',
        currentAgent: 'assessment',
        stateVersion: 3,
        finalAction: '查看当前计划',
        state: {}
      };
      expect(ApiResponseValidator.isValid('POST', '/api/v1/workflows/session-1/run', workflowRun as Object)).assertTrue();

      const proactive: ProactiveResponse = {
        shouldNotify: true,
        channel: 'reminder',
        title: '数据结构考试还有 5 天',
        body: '建议现在补强后序遍历。',
        action: { type: 'focus', targetPage: 'pages/FocusSetup', preset: {} },
        contextTags: ['exam_within_7d'],
        reason: '考试临近且掌握度偏低。',
        factors: [],
        cardData: {}
      };
      expect(ApiResponseValidator.isValid('POST', '/api/v1/agent/proactive', proactive as Object)).assertTrue();
    });

    it('preserves structured server errors and safe HTTP fallbacks', 0, () => {
      const contractError = AgentApiClient.parseServerError(
        '{"code":"PLAN_DIFF_NOT_READY","message":"完成诊断后再查看。","recoverable":true}', 409);
      const invalidBodyError = AgentApiClient.parseServerError('<html>bad gateway</html>', 502);
      const v03Error = AgentApiClient.parseServerError(
        '{"errorCode":"WORKFLOW_NOT_FOUND","message":"会话不存在。","details":{"sessionId":"missing"}}', 404);

      expect(contractError.error.code).assertEqual('PLAN_DIFF_NOT_READY');
      expect(contractError.error.message).assertEqual('完成诊断后再查看。');
      expect(contractError.error.recoverable).assertTrue();
      expect(contractError.error.statusCode).assertEqual(409);
      expect(invalidBodyError.error.code).assertEqual('HTTP_ERROR');
      expect(invalidBodyError.error.message).assertEqual('服务返回 HTTP 502。');
      expect(invalidBodyError.error.recoverable).assertTrue();
      expect(v03Error.error.code).assertEqual('WORKFLOW_NOT_FOUND');
      expect(v03Error.error.message).assertEqual('会话不存在。');
      expect(v03Error.error.recoverable).assertFalse();
    });
  });
}
