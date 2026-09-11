import { AgentApiClient } from '../api/AgentApiClient';
import { DemoResetResponse, TraceResponse } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { ClientCache } from '../cache/ClientCache';
import { DemoSnapshot } from '../cache/DemoSnapshot';

/** Loads explainable Agent trace data and resets the demo through the API. */
export class TraceViewModel {
  private errorMessage: string = '';

  getErrorMessage(): string {
    return this.errorMessage;
  }

  async load(traceId: string, forceRefresh: boolean = false): Promise<TraceResponse | null> {
    this.errorMessage = '';
    const cached: TraceResponse | null = ClientCache.getTrace();
    if (!forceRefresh && cached !== null && cached.traceId === traceId) {
      return cached;
    }
    if (forceRefresh) {
      ClientCache.invalidateTrace();
    }
    const result = await AgentApiClient.getTrace(traceId);
    if (result.ok) {
      ClientCache.cacheTrace(result.data);
      return result.data;
    }
    this.errorMessage = (result as ApiFailure).error.message;
    return null;
  }

  async reset(): Promise<DemoResetResponse | null> {
    const result = await AgentApiClient.resetDemo();
    if (result.ok) {
      DemoSnapshot.clearAfterReset();
      return result.data;
    }
    this.errorMessage = (result as ApiFailure).error.message;
    return null;
  }
}
