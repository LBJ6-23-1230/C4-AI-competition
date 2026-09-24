/** Lightweight runtime guards for JSON received from the api-contract-v0.3 endpoints. */
export class ApiResponseValidator {
  /**
   * 去掉 URL 上的查询串，只留路径。
   *
   * ⚠️ 这个函数是修一个真实缺陷才加的：
   * `listKnowledgeBases(userId)` 会拼出 `/api/v1/knowledge-bases?userId=xxx`，
   * 而本类里对路径用的是**精确比较**（`path === '/api/v1/knowledge-bases'`）——
   * 带查询串时比较不成立，于是掉进下面的「详情」分支去要 `kbId` / `name`，
   * 列表响应里没有这两个字段 → 校验失败 →
   * 页面报「服务返回的数据结构与 api-contract-v0.3 不一致」。
   *
   * 实测复现条件：**必须登录真实账号**（游客不传 userId，反而正常）。
   * 表现为「知识库页进去就报错、没法新建知识库」。
   */
  private static basePath(path: string): string {
    const mark: number = path.indexOf('?');
    return mark >= 0 ? path.substring(0, mark) : path;
  }

  static isValid(method: string, path: string, payload: Object): boolean {
    if (!ApiResponseValidator.isRecord(payload)) {
      return false;
    }
    const data: Record<string, Object> = payload as Record<string, Object>;
    // 一律用去查询串的路径做匹配，避免 `?a=b` 让精确比较失效。
    const route: string = ApiResponseValidator.basePath(path);

    if (method === 'POST' && route === '/api/v1/workflows') {
      return ApiResponseValidator.hasString(data, 'sessionId') &&
        ApiResponseValidator.hasString(data, 'traceId') &&
        ApiResponseValidator.hasString(data, 'status') &&
        ApiResponseValidator.hasString(data, 'currentStep') &&
        ApiResponseValidator.hasString(data, 'nextAction');
    }
    if (method === 'GET' && route.indexOf('/api/v1/workflows/') === 0) {
      return ApiResponseValidator.hasString(data, 'status') &&
        ApiResponseValidator.hasNumber(data, 'stateVersion') &&
        ApiResponseValidator.isNullableString(data, 'currentAgent') &&
        ApiResponseValidator.isNullableString(data, 'finalAction');
    }
    if (method === 'POST' && route.indexOf('/api/v1/workflows/') === 0 && route.endsWith('/run')) {
      return ApiResponseValidator.hasString(data, 'sessionId') &&
        ApiResponseValidator.hasString(data, 'traceId') &&
        ApiResponseValidator.hasString(data, 'status') &&
        ApiResponseValidator.hasString(data, 'currentStep') &&
        ApiResponseValidator.hasString(data, 'currentAgent') &&
        ApiResponseValidator.hasNumber(data, 'stateVersion') &&
        ApiResponseValidator.isNullableString(data, 'finalAction');
    }
    if (method === 'GET' && route.indexOf('/api/v1/profile/') === 0) {
      return ApiResponseValidator.hasNumber(data, 'profileVersion') &&
        ApiResponseValidator.hasArray(data, 'mastery') &&
        ApiResponseValidator.hasArray(data, 'history') &&
        ApiResponseValidator.hasArray(data, 'evidence');
    }
    if (method === 'GET' && route === '/api/v1/plans/current') {
      return ApiResponseValidator.isPlan(data);
    }
    if (method === 'GET' && route.indexOf('/api/v1/exercises/') === 0 && !route.endsWith('/submit')) {
      return ApiResponseValidator.hasString(data, 'setId') && ApiResponseValidator.hasArray(data, 'exercises');
    }
    if (method === 'POST' && route.indexOf('/api/v1/exercises/') === 0 && route.endsWith('/submit')) {
      return ApiResponseValidator.isRecordField(data, 'assessment') &&
        ApiResponseValidator.hasBoolean(data, 'needReplan') &&
        ApiResponseValidator.isNullableRecord(data, 'masteryUpdate');
    }
    if (method === 'GET' && route.indexOf('/api/v1/plans/') === 0 && route.endsWith('/diff')) {
      return ApiResponseValidator.hasNumber(data, 'oldVersion') &&
        ApiResponseValidator.hasNumber(data, 'newVersion') &&
        ApiResponseValidator.hasArray(data, 'changedTasks') &&
        ApiResponseValidator.hasString(data, 'adjustmentReason') &&
        ApiResponseValidator.hasArray(data, 'triggerEvidence');
    }
    if (method === 'GET' && route.indexOf('/api/v1/traces/') === 0) {
      return ApiResponseValidator.hasString(data, 'traceId') && ApiResponseValidator.hasArray(data, 'events');
    }
    if (method === 'POST' && route === '/api/v1/demo/reset') {
      return ApiResponseValidator.hasString(data, 'status') &&
        ApiResponseValidator.hasString(data, 'userId') &&
        ApiResponseValidator.hasString(data, 'traceId') &&
        ApiResponseValidator.isNullableRecord(data, 'profile') &&
        ApiResponseValidator.isNullableRecord(data, 'plan');
    }
    // 学习搭子匹配：五因子确定性算分
    //   matchedCandidate 可能为 null（全部候选人 0 分时），故只校验 candidates 是数组
    if (method === 'POST' && route === '/api/v1/agent/partner-match') {
      return ApiResponseValidator.hasString(data, 'userId') &&
        ApiResponseValidator.hasArray(data, 'candidates') &&
        ApiResponseValidator.hasBoolean(data, 'realModeUnavailable');
    }
    if (method === 'POST' && route === '/api/v1/agent/proactive') {
      return ApiResponseValidator.hasBoolean(data, 'shouldNotify') &&
        ApiResponseValidator.hasString(data, 'channel') &&
        ApiResponseValidator.isString(data, 'title') &&
        ApiResponseValidator.isString(data, 'body') &&
        ApiResponseValidator.isRecordField(data, 'action') &&
        ApiResponseValidator.hasArray(data, 'contextTags') &&
        ApiResponseValidator.hasString(data, 'reason') &&
        ApiResponseValidator.hasArray(data, 'factors') &&
        ApiResponseValidator.isRecordField(data, 'cardData');
    }
    // ---- 知识库（/api/v1/knowledge-bases/**、/api/v1/documents/**）----
    if (method === 'GET' && route.indexOf('/api/v1/knowledge-bases') === 0) {
      if (route.indexOf('/documents') > 0) {
        return ApiResponseValidator.hasString(data, 'kbId') &&
          ApiResponseValidator.hasArray(data, 'documents');
      }
      if (route === '/api/v1/knowledge-bases') {
        return ApiResponseValidator.hasArray(data, 'knowledgeBases') &&
          ApiResponseValidator.hasNumber(data, 'total');
      }
      // 详情：KnowledgeBase + documents
      return ApiResponseValidator.hasString(data, 'kbId') &&
        ApiResponseValidator.hasString(data, 'name') &&
        ApiResponseValidator.hasString(data, 'courseName');
    }
    if (method === 'POST' && route === '/api/v1/knowledge-bases') {
      return ApiResponseValidator.hasString(data, 'kbId') &&
        ApiResponseValidator.hasString(data, 'name');
    }
    if (method === 'DELETE' && route.indexOf('/api/v1/knowledge-bases/') === 0) {
      return ApiResponseValidator.hasString(data, 'status');
    }
    if (method === 'POST' && route.indexOf('/api/v1/knowledge-bases/') === 0
      && route.endsWith('/documents')) {
      return ApiResponseValidator.hasString(data, 'documentId') &&
        ApiResponseValidator.hasString(data, 'status') &&
        ApiResponseValidator.hasString(data, 'fileName');
    }
    if (method === 'DELETE' && route.indexOf('/api/v1/documents/') === 0) {
      return ApiResponseValidator.hasString(data, 'status');
    }
    if (method === 'POST' && route.indexOf('/api/v1/knowledge-bases/') === 0
      && route.endsWith('/search')) {
      return ApiResponseValidator.hasString(data, 'kbId') &&
        ApiResponseValidator.hasString(data, 'query') &&
        ApiResponseValidator.hasArray(data, 'hits') &&
        ApiResponseValidator.hasNumber(data, 'totalScanned') &&
        ApiResponseValidator.hasString(data, 'retrievalMode') &&
        // 语义检索的两个诚实标注字段（契约 required）：
        //   semanticAvailable = 后端是否具备语义能力
        //   semanticWeight    = 本次语义分权重（0 表示未参与）
        ApiResponseValidator.hasBoolean(data, 'semanticAvailable') &&
        ApiResponseValidator.hasNumber(data, 'semanticWeight');
    }
    // ---- 鉴权（/api/v1/auth/*）----
    if (method === 'POST' && route === '/api/v1/auth/register') {
      return ApiResponseValidator.isAuthSession(data);
    }
    if (method === 'POST' && route === '/api/v1/auth/login') {
      return ApiResponseValidator.isAuthSession(data);
    }
    if (method === 'POST' && route === '/api/v1/auth/login-or-register') {
      return ApiResponseValidator.isAuthSession(data);
    }
    if (method === 'POST' && route === '/api/v1/auth/login-with-huawei') {
      return ApiResponseValidator.isAuthSession(data);
    }
    // ⚠️ 手机号验证码登录的两个接口（契约 api-contract-v0.3）：
    //   /api/v1/auth/send-code   -> PhoneCodeSendResponse
    //   /api/v1/auth/verify-code -> AuthLoginOrRegisterResponse（200 已有账号 / 201 新建账号）
    // 这两条原先漏在下面，导致**正确的响应**也落到末尾 `return false`，
    // 被 AgentApiClient 判为 INVALID_RESPONSE —— 验证码登录在联机与 Fixture
    // 两种数据源下都不可用（登录页为此写的分段控件/开发回显/重发倒计时全部作废）。
    if (method === 'POST' && route === '/api/v1/auth/send-code') {
      return ApiResponseValidator.isPhoneCodeSendResponse(data);
    }
    if (method === 'POST' && route === '/api/v1/auth/verify-code') {
      return ApiResponseValidator.isAuthSession(data);
    }
    if (method === 'POST' && route === '/api/v1/auth/logout') {
      return ApiResponseValidator.hasString(data, 'status');
    }
    if (method === 'GET' && route === '/api/v1/auth/me') {
      return ApiResponseValidator.isAuthUserField(data, 'user');
    }
    if (method === 'DELETE' && route === '/api/v1/auth/account') {
      return ApiResponseValidator.hasString(data, 'status');
    }
    return false;
  }

  /** 会话响应：{ user, token, expiresAt }。 */
  private static isAuthSession(data: Record<string, Object>): boolean {
    return ApiResponseValidator.isAuthUserField(data, 'user') &&
      ApiResponseValidator.hasString(data, 'token') &&
      ApiResponseValidator.hasString(data, 'expiresAt');
  }

  /**
   * 验证码签发响应（契约 `PhoneCodeSendResponse`）。
   *
   * required: phoneMasked / expiresInSeconds / resendAfterSeconds / smsDelivered
   * optional: devCode（未配短信服务商时的开发回显码，故意不设为 required）
   */
  private static isPhoneCodeSendResponse(data: Record<string, Object>): boolean {
    return ApiResponseValidator.hasString(data, 'phoneMasked') &&
      ApiResponseValidator.hasNumber(data, 'expiresInSeconds') &&
      ApiResponseValidator.hasNumber(data, 'resendAfterSeconds') &&
      ApiResponseValidator.hasBoolean(data, 'smsDelivered');
  }

  /** 用户视图：userId 与 nickname 必须是非空字符串。 */
  private static isAuthUserField(data: Record<string, Object>, key: string): boolean {
    if (!ApiResponseValidator.isRecordField(data, key)) {
      return false;
    }
    const user: Record<string, Object> = data[key] as Record<string, Object>;
    return ApiResponseValidator.hasString(user, 'userId') &&
      ApiResponseValidator.hasString(user, 'nickname');
  }

  private static isPlan(data: Record<string, Object>): boolean {
    return ApiResponseValidator.isNullableString(data, 'planId') &&
      ApiResponseValidator.hasNumber(data, 'version') &&
      ApiResponseValidator.hasNumber(data, 'generatedFromProfileVersion') &&
      ApiResponseValidator.hasArray(data, 'tasks');
  }

  private static hasString(data: Record<string, Object>, key: string): boolean {
    const value: Object | undefined = data[key] as Object | undefined;
    return typeof value === 'string' && (value as string).trim().length > 0;
  }

  private static isString(data: Record<string, Object>, key: string): boolean {
    return typeof data[key] === 'string';
  }

  private static hasNumber(data: Record<string, Object>, key: string): boolean {
    return typeof data[key] === 'number';
  }

  private static hasBoolean(data: Record<string, Object>, key: string): boolean {
    return typeof data[key] === 'boolean';
  }

  private static hasArray(data: Record<string, Object>, key: string): boolean {
    return Array.isArray(data[key]);
  }

  private static isRecordField(data: Record<string, Object>, key: string): boolean {
    const value: Object | undefined = data[key] as Object | undefined;
    return value !== undefined && ApiResponseValidator.isRecord(value);
  }

  private static isNullableRecord(data: Record<string, Object>, key: string): boolean {
    const value: Object | undefined = data[key] as Object | undefined;
    return value === null || (value !== undefined && ApiResponseValidator.isRecord(value));
  }

  private static isNullableString(data: Record<string, Object>, key: string): boolean {
    const value: Object | undefined = data[key] as Object | undefined;
    return value === null || typeof value === 'string';
  }

  private static isRecord(value: Object): boolean {
    return typeof value === 'object' && value !== null && !Array.isArray(value);
  }
}
