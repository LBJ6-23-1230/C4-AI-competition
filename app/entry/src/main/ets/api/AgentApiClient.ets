import { http } from '@kit.NetworkKit';
import { API_CONTRACT_VERSION, DemoResetResponse, PartnerContactListResponse, PartnerInvitationCreateRequest, PartnerInvitationListResponse, PartnerInvitationResponse, PartnerMatchRequest, PartnerMatchResponse, ExerciseQuery, ExerciseSetResponse, ExerciseSubmission, ExerciseSubmissionResult, KnowledgeBase, KnowledgeBaseCreateRequest, KnowledgeBaseDetail, KnowledgeBaseListResponse, KnowledgeDocument, KnowledgeDocumentDetail, KnowledgeDocumentUploadRequest, KnowledgeSearchRequest, KnowledgeSearchResponse, LearningPlan, PlanDiff, ProactiveRequest, ProactiveResponse, ProfileResponse, TraceResponse, WorkflowCreateRequest, WorkflowResponse, WorkflowRunRequest, WorkflowRunResponse, WorkflowStatusResponse } from './ApiModels';
import { ApiFailure, ApiResult, apiFailure, apiSuccess } from './ApiResult';
import { ApiDefaults } from './ApiDefaults';
import { AuthChangePasswordRequest, AuthChangePasswordResponse, AuthHuaweiLoginRequest, AuthLoginOrRegisterRequest, AuthLoginOrRegisterResponse, AuthLoginRequest, AuthRegisterRequest, AuthSendCodeRequest, AuthSendCodeResponse, AuthSessionResponse, AuthStatusResponse, AuthUserResponse, AuthVerifyCodeRequest } from './AuthModels';
import { AuthStore } from './AuthStore';
import { FixtureApiTransport } from './FixtureApiTransport';
import { ApiResponseValidator } from './ApiResponseValidator';

export interface ApiClientConfig {
  baseUrl: string;
  useFixture: boolean;
  timeoutMs: number;
}

/**
 * The single API entry point. Pages must use ViewModels instead of calling HTTP directly.
 *
 * 联调收敛后只有一个 baseUrl：聊天层 `/api/agent/chat` 与结构化工作流层 `/api/v1/**`
 * 由同一个后端进程、同一个端口提供，不再出现"chat 打 B1、学习流打 B2"的双后端不同源问题。
 *
 * 默认地址集中定义在 `ApiDefaults.DEFAULT_BASE_URL`，页面里不得再各写一份 IP。
 */
export class AgentApiClient {
  private static config: ApiClientConfig = {
    baseUrl: ApiDefaults.DEFAULT_BASE_URL,
    useFixture: ApiDefaults.DEFAULT_USE_FIXTURE,
    timeoutMs: ApiDefaults.DEFAULT_TIMEOUT_MS
  };

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

  static async runWorkflow(sessionId: string, request?: WorkflowRunRequest): Promise<ApiResult<WorkflowRunResponse>> {
    // ⚠️ 必须放宽读超时：这条接口在服务端**逐轮调大模型**推进工作流
    // （`workflows.py` 给 `runtime/loop` 挂了 `QwenAdapter.safe_decide` 作为决策器），
    // 实测首次推进耗时 **11.55 秒**，而默认读超时只有 8 秒 —— 表现为
    // "后端日志 200、前端报连接超时"（同类问题在聊天与出题接口上已经踩过两次，
    // 见 `ApiDefaults.LLM_BOUND_READ_TIMEOUT_MS` 的注释）。
    // `connectTimeout` 仍用配置值：连不上要快速失败，不能陪着一起等。
    return AgentApiClient.request<WorkflowRunResponse>(http.RequestMethod.POST,
      `/api/v1/workflows/${encodeURIComponent(sessionId)}/run`, request,
      ApiDefaults.LLM_BOUND_READ_TIMEOUT_MS);
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
      // 只有显式要求时才拼 generate —— 缺省不带，行为与之前逐字节一致。
      if (query.generate === true) {
        parameters.push('generate=1');
      }
      if (parameters.length > 0) {
        path = `${path}?${parameters.join('&')}`;
      }
    }
    // 要求服务端**现场出题**时放宽读超时：实测一次生成约 10–13 秒，
    // 而默认超时是 8 秒 —— 不放宽必然超时（已实测复现：后端 200、前端报"连接超时"）。
    // 取值必须 > 后端 `LLM_TIMEOUT_SECONDS`（默认 30）。
    return AgentApiClient.request<ExerciseSetResponse>(http.RequestMethod.GET, path, undefined,
      query !== undefined && query.generate === true ? ApiDefaults.LLM_BOUND_READ_TIMEOUT_MS : undefined);
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

  static async getProactiveDecision(request: ProactiveRequest): Promise<ApiResult<ProactiveResponse>> {
    return AgentApiClient.request<ProactiveResponse>(http.RequestMethod.POST, '/api/v1/agent/proactive', request);
  }

  /**
   * 学习搭子匹配 —— 后端**确定性**五因子算分（满分 100）。
   *
   * 为什么不传 candidates：后端在没有 candidates 时会读 `mock_candidates.json`，
   * 与演示基线一致（小红 90 分 / 小刚 70 分）。传了反而容易和文档对不上。
   * 想按真实数据匹配时再传 candidates。
   */
  static async matchPartner(request: PartnerMatchRequest): Promise<ApiResult<PartnerMatchResponse>> {
    return AgentApiClient.request<PartnerMatchResponse>(http.RequestMethod.POST,
      '/api/v1/agent/partner-match', request);
  }

  // ------------------------------------------------ 学习搭子邀请（真正跨账号）
  //
  // ⚠️ 下面这组的 (method, path) 必须与 `ApiResponseValidator` 里的分支**一一对应**，
  // 少一条就会落到校验器末尾的 `return false`：后端明明回了 200，前端却判
  // INVALID_RESPONSE —— 表现为"邀请发不出去 / 收件箱打不开"。
  static async createPartnerInvitation(
    request: PartnerInvitationCreateRequest): Promise<ApiResult<PartnerInvitationResponse>> {
    return AgentApiClient.request<PartnerInvitationResponse>(http.RequestMethod.POST,
      '/api/v1/agent/partner-invitations', request);
  }

  /** 收件箱（默认）或发件箱。收件箱只回**待处理**的那些。 */
  static async listPartnerInvitations(
    box: string = 'inbox'): Promise<ApiResult<PartnerInvitationListResponse>> {
    return AgentApiClient.request<PartnerInvitationListResponse>(http.RequestMethod.GET,
      `/api/v1/agent/partner-invitations?box=${encodeURIComponent(box)}`);
  }

  static async acceptPartnerInvitation(invitationId: string): Promise<ApiResult<PartnerInvitationResponse>> {
    return AgentApiClient.request<PartnerInvitationResponse>(http.RequestMethod.POST,
      `/api/v1/agent/partner-invitations/${encodeURIComponent(invitationId)}/accept`);
  }

  static async declinePartnerInvitation(invitationId: string): Promise<ApiResult<PartnerInvitationResponse>> {
    return AgentApiClient.request<PartnerInvitationResponse>(http.RequestMethod.POST,
      `/api/v1/agent/partner-invitations/${encodeURIComponent(invitationId)}/decline`);
  }

  /** 叉掉 = 无视（只是自己不再看到，与"明确不接受"分开记状态）。 */
  static async dismissPartnerInvitation(invitationId: string): Promise<ApiResult<PartnerInvitationResponse>> {
    return AgentApiClient.request<PartnerInvitationResponse>(http.RequestMethod.POST,
      `/api/v1/agent/partner-invitations/${encodeURIComponent(invitationId)}/dismiss`);
  }

  static async listPartnerContacts(): Promise<ApiResult<PartnerContactListResponse>> {
    return AgentApiClient.request<PartnerContactListResponse>(http.RequestMethod.GET,
      '/api/v1/agent/partner-contacts');
  }

  // ------------------------------------------------------------------ 知识库
  static async listKnowledgeBases(userId?: string): Promise<ApiResult<KnowledgeBaseListResponse>> {
    const suffix: string = userId !== undefined && userId.length > 0
      ? `?userId=${encodeURIComponent(userId)}` : '';
    return AgentApiClient.request<KnowledgeBaseListResponse>(http.RequestMethod.GET,
      `/api/v1/knowledge-bases${suffix}`);
  }

  static async createKnowledgeBase(request: KnowledgeBaseCreateRequest): Promise<ApiResult<KnowledgeBase>> {
    return AgentApiClient.request<KnowledgeBase>(http.RequestMethod.POST,
      '/api/v1/knowledge-bases', request);
  }

  static async getKnowledgeBase(kbId: string): Promise<ApiResult<KnowledgeBaseDetail>> {
    return AgentApiClient.request<KnowledgeBaseDetail>(http.RequestMethod.GET,
      `/api/v1/knowledge-bases/${encodeURIComponent(kbId)}`);
  }

  static async deleteKnowledgeBase(kbId: string): Promise<ApiResult<KnowledgeBase>> {
    return AgentApiClient.request<KnowledgeBase>(http.RequestMethod.DELETE,
      `/api/v1/knowledge-bases/${encodeURIComponent(kbId)}`);
  }

  static async uploadKnowledgeDocument(kbId: string,
    request: KnowledgeDocumentUploadRequest): Promise<ApiResult<KnowledgeDocument>> {
    return AgentApiClient.request<KnowledgeDocument>(http.RequestMethod.POST,
      `/api/v1/knowledge-bases/${encodeURIComponent(kbId)}/documents`, request);
  }

  /**
   * 文档详情（**含切片正文**）。
   *
   * 为什么必须有它：文档列表只回元信息（文件名 / 字数 / 片段数 / 知识点），
   * 正文在 `chunks` 集合里，只有这条接口能读到 —— 没有它就表现为
   * "上传了讲义却看不了内容"。
   * 响应里 `chunkTotal` / `chunksTruncated` 是后端的截断标注，前端照实展示。
   */
  static async getKnowledgeDocument(documentId: string): Promise<ApiResult<KnowledgeDocumentDetail>> {
    return AgentApiClient.request<KnowledgeDocumentDetail>(http.RequestMethod.GET,
      `/api/v1/documents/${encodeURIComponent(documentId)}`);
  }

  static async deleteKnowledgeDocument(documentId: string): Promise<ApiResult<KnowledgeDocument>> {
    return AgentApiClient.request<KnowledgeDocument>(http.RequestMethod.DELETE,
      `/api/v1/documents/${encodeURIComponent(documentId)}`);
  }

  static async searchKnowledgeBase(kbId: string,
    request: KnowledgeSearchRequest): Promise<ApiResult<KnowledgeSearchResponse>> {
    return AgentApiClient.request<KnowledgeSearchResponse>(http.RequestMethod.POST,
      `/api/v1/knowledge-bases/${encodeURIComponent(kbId)}/search`, request);
  }

  // ------------------------------------------------------------------ 鉴权
  static async authRegister(request: AuthRegisterRequest): Promise<ApiResult<AuthSessionResponse>> {
    return AgentApiClient.request<AuthSessionResponse>(http.RequestMethod.POST, '/api/v1/auth/register', request);
  }

  static async authLogin(request: AuthLoginRequest): Promise<ApiResult<AuthSessionResponse>> {
    return AgentApiClient.request<AuthSessionResponse>(http.RequestMethod.POST, '/api/v1/auth/login', request);
  }

  /**
   * 登录优先、注册兜底。登录页主按钮应当调这个：
   * 昵称已存在就登录，不存在才建号 —— 避免"再点一次又建一个新账号"。
   * 响应里的 `created` 用于区分文案（"欢迎回来" / "已为你建号"）。
   */
  static async authLoginOrRegister(request: AuthLoginOrRegisterRequest): Promise<ApiResult<AuthLoginOrRegisterResponse>> {
    return AgentApiClient.request<AuthLoginOrRegisterResponse>(http.RequestMethod.POST, '/api/v1/auth/login-or-register', request);
  }

  /** 华为账号登录：用 `@kit.AccountKit` 拿到的 OpenID 换取本服务 token。 */
  static async authLoginWithHuawei(request: AuthHuaweiLoginRequest): Promise<ApiResult<AuthLoginOrRegisterResponse>> {
    return AgentApiClient.request<AuthLoginOrRegisterResponse>(http.RequestMethod.POST, '/api/v1/auth/login-with-huawei', request);
  }

  /**
   * 发送手机号验证码。
   *
   * 后端限流：同号 60 秒一次、滚动 24 小时最多 10 次。
   * 未配置短信服务商时响应里 `smsDelivered=false` 且（仅非生产环境）回显 `devCode`。
   */
  static async authSendCode(request: AuthSendCodeRequest): Promise<ApiResult<AuthSendCodeResponse>> {
    return AgentApiClient.request<AuthSendCodeResponse>(http.RequestMethod.POST, '/api/v1/auth/send-code', request);
  }

  /**
   * 校验验证码并登录 / 自动注册。
   *
   * 响应形状与 `login-or-register` 相同（含 `created`），
   * 便于前端复用同一套「登录成功 / 已建号」文案逻辑。
   */
  static async authVerifyCode(request: AuthVerifyCodeRequest): Promise<ApiResult<AuthLoginOrRegisterResponse>> {
    return AgentApiClient.request<AuthLoginOrRegisterResponse>(http.RequestMethod.POST, '/api/v1/auth/verify-code', request);
  }

  static async authMe(): Promise<ApiResult<AuthUserResponse>> {
    return AgentApiClient.request<AuthUserResponse>(http.RequestMethod.GET, '/api/v1/auth/me');
  }

  static async authChangePassword(request: AuthChangePasswordRequest): Promise<ApiResult<AuthChangePasswordResponse>> {
    return AgentApiClient.request<AuthChangePasswordResponse>(http.RequestMethod.POST,
      '/api/v1/auth/change-password', request);
  }

  static async authLogout(): Promise<ApiResult<AuthStatusResponse>> {
    return AgentApiClient.request<AuthStatusResponse>(http.RequestMethod.POST, '/api/v1/auth/logout');
  }

  static async authDeleteAccount(): Promise<ApiResult<AuthStatusResponse>> {
    return AgentApiClient.request<AuthStatusResponse>(http.RequestMethod.DELETE, '/api/v1/auth/account');
  }

  private static async request<T>(method: http.RequestMethod, path: string, body?: Object,
    readTimeoutOverrideMs?: number): Promise<ApiResult<T>> {
    const methodName: string = AgentApiClient.methodName(method);
    if (AgentApiClient.config.useFixture) return FixtureApiTransport.request<T>(methodName, path, body);

    // 少数接口会**在服务端调大模型**（如带 `generate=1` 的题集）。
    // 那些接口必须放宽读超时，否则客户端会在服务端出题完成前掐断 ——
    // 表现为"连接超时或网络不可用"，而后端日志里明明是一条 200。
    const readTimeoutMs: number = Math.max(
      AgentApiClient.config.timeoutMs,
      readTimeoutOverrideMs !== undefined ? readTimeoutOverrideMs : 0);

    const httpRequest: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Accept': 'application/json',
        'X-API-Contract-Version': API_CONTRACT_VERSION
      };
      if (body !== undefined) {
        header['Content-Type'] = 'application/json';
      }
      // 已登录时带上凭据。游客 / 离线演示不带 Authorization，
      // 后端按 demo-user 处理，演示主链数值完全不受影响。
      const token: string = AuthStore.getToken();
      if (token.length > 0) {
        header['Authorization'] = `Bearer ${token}`;
      }
      const requestOptions: http.HttpRequestOptions = {
        method: method,
        header: header,
        extraData: body === undefined ? undefined : JSON.stringify(body),
        expectDataType: http.HttpDataType.STRING,
        // ⚠️ `connectTimeout` 始终用配置值（连不上要快速失败），
        // 但 `readTimeout` 允许单次调用放宽 —— 见 `readTimeoutMs` 参数。
        connectTimeout: AgentApiClient.config.timeoutMs,
        readTimeout: readTimeoutMs
      };
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
          return apiFailure('INVALID_RESPONSE', `服务返回的数据结构与 ${API_CONTRACT_VERSION} 不一致。`, false, 'network');
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

  /** 把 http.RequestMethod 映射成字符串，供 Fixture 路由与响应校验使用。 */
  private static methodName(method: http.RequestMethod): string {
    if (method === http.RequestMethod.GET) return 'GET';
    if (method === http.RequestMethod.DELETE) return 'DELETE';
    if (method === http.RequestMethod.PUT) return 'PUT';
    return 'POST';
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
      const errorCode: Object | undefined = parsed['errorCode'] as Object | undefined;
      const legacyCode: Object | undefined = parsed['code'] as Object | undefined;
      const serverCode: Object | undefined = errorCode !== undefined ? errorCode : legacyCode;
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
