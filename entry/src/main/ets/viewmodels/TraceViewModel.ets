import { AgentApiClient } from '../api/AgentApiClient';
import { DemoResetResponse, TraceResponse } from '../api/ApiModels';
import { ClientCache } from '../cache/ClientCache';
import { DemoSnapshot } from '../cache/DemoSnapshot';

/** Loads explainable Agent trace data and resets the demo through the API. */
export class TraceViewModel {
  async load(traceId: string): Promise<TraceResponse | null> {
    const cached: TraceResponse | null = ClientCache.getTrace();
    if (cached !== null && cached.traceId === traceId) {
      return cached;
    }
    const result = await AgentApiClient.getTrace(traceId);
    if (result.ok) {
      ClientCache.cacheTrace(result.data);
      return result.data;
    }
    return null;
  }

  async reset(): Promise<DemoResetResponse | null> {
    const result = await AgentApiClient.resetDemo();
    if (result.ok) {
      DemoSnapshot.clearAfterReset();
      return result.data;
    }
    return null;
  }
}
