import { AgentApiClient } from '../api/AgentApiClient';
import { ProactiveRequest, ProactiveResponse, ProfileResponse } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { ClientCache } from '../cache/ClientCache';

export interface ProactiveViewState {
  decision: ProactiveResponse | null;
  errorMessage: string;
}

export class ProactiveViewModel {
  async load(userId: string, daysLeft: number, foreground: boolean = true): Promise<ProactiveViewState> {
    const profile: ProfileResponse | null = ClientCache.getProfile();
    const masteryScore: number = profile !== null && profile.mastery.length > 0
      ? profile.mastery[0].masteryScore : 58;
    const request: ProactiveRequest = {
      userId: userId,
      context: {
        now: new Date().toISOString(),
        foreground: foreground,
        focusSessionActive: false,
        masteryScore: masteryScore,
        errorIntensity: 67,
        daysLeft: Math.max(0, daysLeft),
        importance: 90
      }
    };
    const result = await AgentApiClient.getProactiveDecision(request);
    if (result.ok) return { decision: result.data, errorMessage: '' };
    return { decision: null, errorMessage: (result as ApiFailure).error.message };
  }
}
