import { http } from '@kit.NetworkKit';
import { API_CONTRACT_VERSION, DemoResetResponse, ExerciseSetResponse, ExerciseSubmission, ExerciseSubmissionResult, LearningPlan, PlanDiff, ProfileResponse, TraceResponse, WorkflowCreateRequest, WorkflowResponse, WorkflowStatusResponse } from './ApiModels';
import { ApiResult, apiFailure, apiSuccess } from './ApiResult';
import { FixtureApiTransport } from './FixtureApiTransport';

export interface ApiClientConfig {
  baseUrl: string;
  useFixture: boolean;
  timeoutMs: number;
}

/** The single API entry point. Pages must use ViewModels instead of calling HTTP directly. */
export class AgentApiClient {
  private static config: ApiClientConfig = { baseUrl: 'http://10.0.2.2:5000', useFixture: true, timeoutMs: 8000 };

  static getConfig(): ApiClientConfig {
    return { baseUrl: AgentApiClient.config.baseUrl, useFixture: AgentApiClient.config.useFixture, timeoutMs: AgentApiClient.config.timeoutMs };
  }

  static configure(config: ApiClientConfig): void {
    AgentApiClient.config = { baseUrl: AgentApiClient.normalizeBaseUrl(config.baseUrl), useFixture: config.useFixture, timeoutMs: config.timeoutMs };
  }

  static setBaseUrl(baseUrl: string): void { AgentApiClient.config.baseUrl = AgentApiClient.normalizeBaseUrl(baseUrl); }
  static setUseFixture(useFixture: boolean): void { AgentApiClient.config.useFixture = useFixture; }

  static async createWorkflow(request: WorkflowCreateRequest): Promise<ApiResult<WorkflowResponse>> {
    return AgentApiClient.request<WorkflowResponse>(http.RequestMethod.POST, '/api/v1/workflows', request);
  }

  static async getWorkflow(sessionId: string): Promise<ApiResult<WorkflowStatusResponse>> {
    return AgentApiClient.request<WorkflowStatusResponse>(http.RequestMethod.GET, `/api/v1/workflows/${encodeURIComponent(sessionId)}`);
  }

  static async getProfile(userId: string): Promise<ApiResult<ProfileResponse>> {
    return AgentApiClient.request<ProfileResponse>(http.RequestMethod.GET, `/api/v1/profile/${encodeURIComponent(userId)}`);
  }

  static async getCurrentPlan(): Promise<ApiResult<LearningPlan>> {
    return AgentApiClient.request<LearningPlan>(http.RequestMethod.GET, '/api/v1/plans/current');
  }

  static async getExerciseSet(setId: string): Promise<ApiResult<ExerciseSetResponse>> {
    return AgentApiClient.request<ExerciseSetResponse>(http.RequestMethod.GET, `/api/v1/exercises/${encodeURIComponent(setId)}`);
  }

  static async submitExercise(setId: string, submission: ExerciseSubmission): Promise<ApiResult<ExerciseSubmissionResult>> {
    return AgentApiClient.request<ExerciseSubmissionResult>(http.RequestMethod.POST, `/api/v1/exercises/${encodeURIComponent(setId)}/submit`, submission);
  }

  static async getPlanDiff(planId: string): Promise<ApiResult<PlanDiff>> {
    return AgentApiClient.request<PlanDiff>(http.RequestMethod.GET, `/api/v1/plans/${encodeURIComponent(planId)}/diff`);
  }

  static async getTrace(traceId: string): Promise<ApiResult<TraceResponse>> {
    return AgentApiClient.request<TraceResponse>(http.RequestMethod.GET, `/api/v1/traces/${encodeURIComponent(traceId)}`);
  }

  static async resetDemo(): Promise<ApiResult<DemoResetResponse>> {
    return AgentApiClient.request<DemoResetResponse>(http.RequestMethod.POST, '/api/v1/demo/reset');
  }

  private static async request<T>(method: http.RequestMethod, path: string, body?: Object): Promise<ApiResult<T>> {
    const methodName: string = method === http.RequestMethod.GET ? 'GET' : 'POST';
    if (AgentApiClient.config.useFixture) return FixtureApiTransport.request<T>(methodName, path, body);

    try {
      const requestOptions: http.HttpRequestOptions = body === undefined
        ? { method: method, header: { 'Accept': 'application/json', 'X-API-Contract-Version': API_CONTRACT_VERSION }, connectTimeout: AgentApiClient.config.timeoutMs, readTimeout: AgentApiClient.config.timeoutMs }
        : { method: method, header: { 'Accept': 'application/json', 'Content-Type': 'application/json', 'X-API-Contract-Version': API_CONTRACT_VERSION }, extraData: JSON.stringify(body), connectTimeout: AgentApiClient.config.timeoutMs, readTimeout: AgentApiClient.config.timeoutMs };
      const response: http.HttpResponse = await http.createHttp().request(`${AgentApiClient.config.baseUrl}${path}`, requestOptions);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        return apiFailure('HTTP_ERROR', `服务返回 HTTP ${response.responseCode}`, response.responseCode >= 500, 'network', response.responseCode);
      }
      const payload: string = response.result as string;
      if (payload.length === 0) return apiFailure('EMPTY_RESPONSE', '服务未返回可解析的数据。', true, 'network');
      return apiSuccess<T>(JSON.parse(payload) as T, 'network');
    } catch (err) {
      return apiFailure('NETWORK_ERROR', '网络连接失败，请检查服务地址后重试。', true, 'network');
    }
  }

  private static normalizeBaseUrl(baseUrl: string): string {
    const trimmed: string = baseUrl.trim();
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }
}
