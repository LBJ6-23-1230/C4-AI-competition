/** Lightweight runtime guards for JSON received from the api-contract-v0.3 endpoints. */
export class ApiResponseValidator {
  static isValid(method: string, path: string, payload: Object): boolean {
    if (!ApiResponseValidator.isRecord(payload)) {
      return false;
    }
    const data: Record<string, Object> = payload as Record<string, Object>;

    if (method === 'POST' && path === '/api/v1/workflows') {
      return ApiResponseValidator.hasString(data, 'sessionId') &&
        ApiResponseValidator.hasString(data, 'traceId') &&
        ApiResponseValidator.hasString(data, 'status') &&
        ApiResponseValidator.hasString(data, 'currentStep') &&
        ApiResponseValidator.hasString(data, 'nextAction');
    }
    if (method === 'GET' && path.indexOf('/api/v1/workflows/') === 0) {
      return ApiResponseValidator.hasString(data, 'status') &&
        ApiResponseValidator.hasNumber(data, 'stateVersion') &&
        ApiResponseValidator.isNullableString(data, 'currentAgent') &&
        ApiResponseValidator.isNullableString(data, 'finalAction');
    }
    if (method === 'POST' && path.indexOf('/api/v1/workflows/') === 0 && path.endsWith('/run')) {
      return ApiResponseValidator.hasString(data, 'sessionId') &&
        ApiResponseValidator.hasString(data, 'traceId') &&
        ApiResponseValidator.hasString(data, 'status') &&
        ApiResponseValidator.hasString(data, 'currentStep') &&
        ApiResponseValidator.hasString(data, 'currentAgent') &&
        ApiResponseValidator.hasNumber(data, 'stateVersion') &&
        ApiResponseValidator.isNullableString(data, 'finalAction');
    }
    if (method === 'GET' && path.indexOf('/api/v1/profile/') === 0) {
      return ApiResponseValidator.hasNumber(data, 'profileVersion') &&
        ApiResponseValidator.hasArray(data, 'mastery') &&
        ApiResponseValidator.hasArray(data, 'history') &&
        ApiResponseValidator.hasArray(data, 'evidence');
    }
    if (method === 'GET' && path === '/api/v1/plans/current') {
      return ApiResponseValidator.isPlan(data);
    }
    if (method === 'GET' && path.indexOf('/api/v1/exercises/') === 0 && !path.endsWith('/submit')) {
      return ApiResponseValidator.hasString(data, 'setId') && ApiResponseValidator.hasArray(data, 'exercises');
    }
    if (method === 'POST' && path.indexOf('/api/v1/exercises/') === 0 && path.endsWith('/submit')) {
      return ApiResponseValidator.isRecordField(data, 'assessment') &&
        ApiResponseValidator.hasBoolean(data, 'needReplan') &&
        ApiResponseValidator.isNullableRecord(data, 'masteryUpdate');
    }
    if (method === 'GET' && path.indexOf('/api/v1/plans/') === 0 && path.endsWith('/diff')) {
      return ApiResponseValidator.hasNumber(data, 'oldVersion') &&
        ApiResponseValidator.hasNumber(data, 'newVersion') &&
        ApiResponseValidator.hasArray(data, 'changedTasks') &&
        ApiResponseValidator.hasString(data, 'adjustmentReason') &&
        ApiResponseValidator.hasArray(data, 'triggerEvidence');
    }
    if (method === 'GET' && path.indexOf('/api/v1/traces/') === 0) {
      return ApiResponseValidator.hasString(data, 'traceId') && ApiResponseValidator.hasArray(data, 'events');
    }
    if (method === 'POST' && path === '/api/v1/demo/reset') {
      return ApiResponseValidator.hasString(data, 'status') &&
        ApiResponseValidator.hasString(data, 'userId') &&
        ApiResponseValidator.hasString(data, 'traceId') &&
        ApiResponseValidator.isNullableRecord(data, 'profile') &&
        ApiResponseValidator.isNullableRecord(data, 'plan');
    }
    if (method === 'POST' && path === '/api/v1/agent/proactive') {
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
    if (method === 'GET' && path.indexOf('/api/v1/knowledge-bases') === 0) {
      if (path.indexOf('/documents') > 0) {
        return ApiResponseValidator.hasString(data, 'kbId') &&
          ApiResponseValidator.hasArray(data, 'documents');
      }
      if (path === '/api/v1/knowledge-bases') {
        return ApiResponseValidator.hasArray(data, 'knowledgeBases') &&
          ApiResponseValidator.hasNumber(data, 'total');
      }
      // 详情：KnowledgeBase + documents
      return ApiResponseValidator.hasString(data, 'kbId') &&
        ApiResponseValidator.hasString(data, 'name') &&
        ApiResponseValidator.hasString(data, 'courseName');
    }
    if (method === 'POST' && path === '/api/v1/knowledge-bases') {
      return ApiResponseValidator.hasString(data, 'kbId') &&
        ApiResponseValidator.hasString(data, 'name');
    }
    if (method === 'DELETE' && path.indexOf('/api/v1/knowledge-bases/') === 0) {
      return ApiResponseValidator.hasString(data, 'status');
    }
    if (method === 'POST' && path.indexOf('/api/v1/knowledge-bases/') === 0
      && path.endsWith('/documents')) {
      return ApiResponseValidator.hasString(data, 'documentId') &&
        ApiResponseValidator.hasString(data, 'status') &&
        ApiResponseValidator.hasString(data, 'fileName');
    }
    if (method === 'DELETE' && path.indexOf('/api/v1/documents/') === 0) {
      return ApiResponseValidator.hasString(data, 'status');
    }
    if (method === 'POST' && path.indexOf('/api/v1/knowledge-bases/') === 0
      && path.endsWith('/search')) {
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
    if (method === 'POST' && path === '/api/v1/auth/register') {
      return ApiResponseValidator.isAuthSession(data);
    }
    if (method === 'POST' && path === '/api/v1/auth/login') {
      return ApiResponseValidator.isAuthSession(data);
    }
    if (method === 'POST' && path === '/api/v1/auth/login-or-register') {
      return ApiResponseValidator.isAuthSession(data);
    }
    if (method === 'POST' && path === '/api/v1/auth/login-with-huawei') {
      return ApiResponseValidator.isAuthSession(data);
    }
    if (method === 'POST' && path === '/api/v1/auth/logout') {
      return ApiResponseValidator.hasString(data, 'status');
    }
    if (method === 'GET' && path === '/api/v1/auth/me') {
      return ApiResponseValidator.isAuthUserField(data, 'user');
    }
    if (method === 'DELETE' && path === '/api/v1/auth/account') {
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
