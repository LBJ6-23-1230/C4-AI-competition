import { AgentApiClient } from '../api/AgentApiClient';
import { ProactiveRequest, ProactiveResponse, ProfileResponse } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { ClientCache } from '../cache/ClientCache';

export interface ProactiveViewState {
  decision: ProactiveResponse | null;
  errorMessage: string;
}

export class ProactiveViewModel {
  static buildRequest(userId: string, daysLeft: number, foreground: boolean,
    focusSessionActive: boolean, lastStudyAt?: string): ProactiveRequest {
    const profile: ProfileResponse | null = ClientCache.getProfile();
    let masteryScore: number | undefined = undefined;
    if (profile !== null && profile.mastery.length > 0) {
      masteryScore = profile.mastery[0].masteryScore;
      for (let index: number = 1; index < profile.mastery.length; index++) {
        masteryScore = Math.min(masteryScore, profile.mastery[index].masteryScore);
      }
    }
    const request: ProactiveRequest = {
      userId: userId,
      context: {
        now: new Date().toISOString(),
        foreground: foreground,
        focusSessionActive: focusSessionActive,
        daysLeft: Math.max(0, daysLeft)
      }
    };
    if (masteryScore !== undefined) request.context.masteryScore = masteryScore;
    if (lastStudyAt !== undefined && lastStudyAt.length > 0) request.context.lastStudyAt = lastStudyAt;
    return request;
  }

  async load(userId: string, daysLeft: number, foreground: boolean = true,
    focusSessionActive: boolean = false, lastStudyAt?: string): Promise<ProactiveViewState> {
    const request: ProactiveRequest = ProactiveViewModel.buildRequest(
      userId, daysLeft, foreground, focusSessionActive, lastStudyAt);
    const result = await AgentApiClient.getProactiveDecision(request);
    if (result.ok) return { decision: result.data, errorMessage: '' };
    return { decision: null, errorMessage: (result as ApiFailure).error.message };
  }
}
