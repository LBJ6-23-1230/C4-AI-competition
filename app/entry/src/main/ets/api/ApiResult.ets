export type ApiDataSource = 'network' | 'fixture';

export class ApiError {
  readonly code: string;
  readonly message: string;
  readonly recoverable: boolean;
  readonly statusCode: number;

  constructor(code: string, message: string, recoverable: boolean, statusCode: number = 0) {
    this.code = code;
    this.message = message;
    this.recoverable = recoverable;
    this.statusCode = statusCode;
  }
}

export interface ApiSuccess<T> {
  ok: true;
  data: T;
  source: ApiDataSource;
}

export interface ApiFailure {
  ok: false;
  error: ApiError;
  source: ApiDataSource;
}

export type ApiResult<T> = ApiSuccess<T> | ApiFailure;

export function apiSuccess<T>(data: T, source: ApiDataSource): ApiSuccess<T> {
  return { ok: true, data: data, source: source };
}

export function apiFailure(code: string, message: string, recoverable: boolean, source: ApiDataSource, statusCode: number = 0): ApiFailure {
  return { ok: false, error: new ApiError(code, message, recoverable, statusCode), source: source };
}
