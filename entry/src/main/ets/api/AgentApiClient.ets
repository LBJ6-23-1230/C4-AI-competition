import { http } from '@kit.NetworkKit';
import { API_CONTRACT_VERSION, DemoResetResponse, ExerciseQuery, ExerciseSetResponse, ExerciseSubmission, ExerciseSubmissionResult, LearningPlan, PlanDiff, ProfileResponse, TraceResponse, WorkflowCreateRequest, WorkflowResponse, WorkflowStatusResponse } from './ApiModels';
import { ApiFailure, ApiResult, apiFailure, apiSuccess } from './ApiResult';
import { FixtureApiTransport } from './FixtureApiTransport';
import { ApiResponseValidator } from './ApiResponseValidator';

export interface ApiClientConfig {
  baseUrl: string;
  useFixture: boolean;
  timeoutMs: number;
}

/** The single API entry point. Pages must use ViewModels instead of calling HTTP directly. */
export class AgentApiClient {
  private static config: ApiClientConfig = { baseUrl: 'http://10.0.2.2:5000', useFixture: false, timeoutMs: 8000 };

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

  static async getExerciseSet(setId: string, query?: ExerciseQuery): Promise<ApiResult<ExerciseSetResponse>> {
    let path: string = `/api/v1/exercises/${encodeURIComponent(setId)}`;
    if (query !== undefined) {
      const parameters: string[] = [];
      if (query.knowledgePointId !== undefined && query.knowledgePointId.trim().length > 0) {
        parameters.push(`knowledgePointId=${encodeURIComponent(query.knowledgePointId)}`);
      }
      if (query.difficulty !== undefined && query.difficulty.trim().length > 0) {
        parameters.push(`difficulty=${encodeURIComponent(query.difficulty)}`);
      }
      if (query.count !== undefined) {
        parameters.push(`count=${query.count}`);
      }
      if (query.excludeExerciseIds !== undefined) {
        for (let index: number = 0; index < query.excludeExerciseIds.length; index++) {
          parameters.push(`excludeExerciseId=${encodeURIComponent(query.excludeExerciseIds[index])}`);
        }
      }
      if (parameters.length > 0) {
        path = `${path}?${parameters.join('&')}`;
      }
    }
    return AgentApiClient.request<ExerciseSetResponse>(http.RequestMethod.GET, path);
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

    const httpRequest: http.HttpRequest = http.createHttp();
    try {
      const requestOptions: http.HttpRequestOptions = body === undefined
        ? { method: method, header: { 'Accept': 'application/json', 'X-API-Contract-Version': API_CONTRACT_VERSION }, expectDataType: http.HttpDataType.STRING, connectTimeout: AgentApiClient.config.timeoutMs, readTimeout: AgentApiClient.config.timeoutMs }
        : { method: method, header: { 'Accept': 'application/json', 'Content-Type': 'application/json', 'X-API-Contract-Version': API_CONTRACT_VERSION }, extraData: JSON.stringify(body), expectDataType: http.HttpDataType.STRING, connectTimeout: AgentApiClient.config.timeoutMs, readTimeout: AgentApiClient.config.timeoutMs };
      const response: http.HttpResponse =
        await httpRequest.request(`${AgentApiClient.config.baseUrl}${path}`, requestOptions);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        return AgentApiClient.parseServerError(response.result as string, response.responseCode);
      }
      const payload: string = (response.result as string).trim();
      if (payload.length === 0) return apiFailure('EMPTY_RESPONSE', '服务未返回可解析的数据。', true, 'network');
      try {
        const parsed: Object = JSON.parse(payload) as Object;
        if (!ApiResponseValidator.isValid(methodName, path, parsed)) {
          return apiFailure('INVALID_RESPONSE', '服务返回的数据结构与 api-contract-v0.2 不一致。', false, 'network');
        }
        return apiSuccess<T>(parsed as T, 'network');
      } catch (parseError) {
        return apiFailure('INVALID_RESPONSE', '服务返回的数据格式不正确，请联系联调同学检查接口响应。', false, 'network');
      }
    } catch (err) {
      return apiFailure('NETWORK_ERROR', '连接超时或网络不可用，请检查服务地址后重试。', true, 'network');
    } finally {
      httpRequest.destroy();
    }
  }

  private static normalizeBaseUrl(baseUrl: string): string {
    const trimmed: string = baseUrl.trim();
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }

  static parseServerError(payload: string, statusCode: number): ApiFailure {
    const defaultRecoverable: boolean = statusCode >= 500 || statusCode === 408 || statusCode === 429;
    let code: string = 'HTTP_ERROR';
    let message: string = AgentApiClient.httpErrorMessage(statusCode);
    let recoverable: boolean = defaultRecoverable;
    try {
      const parsed: Record<string, Object> = JSON.parse(payload.trim()) as Record<string, Object>;
      const serverCode: Object | undefined = parsed['code'] as Object | undefined;
      const serverMessage: Object | undefined = parsed['message'] as Object | undefined;
      const serverRecoverable: Object | undefined = parsed['recoverable'] as Object | undefined;
      if (typeof serverCode === 'string' && (serverCode as string).trim().length > 0) {
        code = serverCode as string;
      }
      if (typeof serverMessage === 'string' && (serverMessage as string).trim().length > 0) {
        message = serverMessage as string;
      }
      if (typeof serverRecoverable === 'boolean') {
        recoverable = serverRecoverable as boolean;
      }
    } catch (parseError) {
      // Non-JSON error bodies keep the stable client-side fallback above.
    }
    return apiFailure(code, message, recoverable, 'network', statusCode);
  }

  private static httpErrorMessage(statusCode: number): string {
    if (statusCode === 401 || statusCode === 403) return '服务拒绝访问，请检查鉴权配置。';
    if (statusCode === 404) return '未找到对应接口，请检查服务地址和接口版本。';
    if (statusCode === 408) return '服务响应超时，请稍后重试。';
    if (statusCode === 429) return '服务请求过于频繁，请稍后重试。';
    return `服务返回 HTTP ${statusCode}。`;
  }
}
