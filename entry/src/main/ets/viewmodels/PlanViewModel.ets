import { AgentApiClient } from '../api/AgentApiClient';
import { LearningPlan } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { ClientCache } from '../cache/ClientCache';

export interface PlanViewState {
  plan: LearningPlan | null;
  errorMessage: string;
  isCached: boolean;
}

/** Reads the current plan from the contract API without creating plan data locally. */
export class PlanViewModel {
  async load(forceRefresh: boolean = false): Promise<PlanViewState> {
    const cached: LearningPlan | null = ClientCache.getCurrentPlan();
    if (!forceRefresh && cached !== null) {
      return { plan: cached, errorMessage: '', isCached: true };
    }

    const result = await AgentApiClient.getCurrentPlan();
    if (result.ok) {
      ClientCache.cacheCurrentPlan(result.data);
      return { plan: result.data, errorMessage: '', isCached: false };
    }

    const detail: string = (result as ApiFailure).error.message;
    if (cached !== null) {
      return { plan: cached, errorMessage: `${detail} 正在显示刚才获取的数据。`, isCached: true };
    }
    return { plan: null, errorMessage: detail, isCached: false };
  }
}
