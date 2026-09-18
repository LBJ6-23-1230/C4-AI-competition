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
    return false;
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
