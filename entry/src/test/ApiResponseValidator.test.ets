import { describe, it, expect } from '@ohos/hypium';
import { ApiResponseValidator } from '../main/ets/api/ApiResponseValidator';
import { AgentApiClient } from '../main/ets/api/AgentApiClient';

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
    });

    it('preserves structured server errors and safe HTTP fallbacks', 0, () => {
      const contractError = AgentApiClient.parseServerError(
        '{"code":"PLAN_DIFF_NOT_READY","message":"完成诊断后再查看。","recoverable":true}', 409);
      const invalidBodyError = AgentApiClient.parseServerError('<html>bad gateway</html>', 502);

      expect(contractError.error.code).assertEqual('PLAN_DIFF_NOT_READY');
      expect(contractError.error.message).assertEqual('完成诊断后再查看。');
      expect(contractError.error.recoverable).assertTrue();
      expect(contractError.error.statusCode).assertEqual(409);
      expect(invalidBodyError.error.code).assertEqual('HTTP_ERROR');
      expect(invalidBodyError.error.message).assertEqual('服务返回 HTTP 502。');
      expect(invalidBodyError.error.recoverable).assertTrue();
    });
  });
}
