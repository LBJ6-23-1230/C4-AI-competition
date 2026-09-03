import { AgentApiClient } from '../api/AgentApiClient';
import { Evidence, KnowledgeMastery, MasteryHistory, ProfileResponse } from '../api/ApiModels';
import { ClientCache } from '../cache/ClientCache';

/**
 * Data prepared for the knowledge-profile page.
 * It converts API responses into page-friendly state, but never calculates
 * mastery or decides a new learning plan.
 */
export interface ProfileViewState {
  userId: string;
  profileVersion: number;
  goal: string;
  mastery: KnowledgeMastery[];
  history: MasteryHistory[];
  evidence: Evidence[];
  errorMessage: string;
  isCached: boolean;
}

export class ProfileViewModel {
  async load(userId: string, forceRefresh: boolean = false): Promise<ProfileViewState> {
    const cached: ProfileResponse | null = ClientCache.getProfile();
    if (!forceRefresh && cached !== null) {
      return this.toViewState(cached, true);
    }

    const result = await AgentApiClient.getProfile(userId);
    if (result.ok) {
      ClientCache.cacheProfile(result.data);
      return this.toViewState(result.data, false);
    }

    if (cached !== null) {
      const state: ProfileViewState = this.toViewState(cached, true);
      state.errorMessage = '网络暂不可用，正在显示刚才获取的数据。';
      return state;
    }

    return {
      userId: userId,
      profileVersion: 0,
      goal: '',
      mastery: [],
      history: [],
      evidence: [],
      errorMessage: '知识画像加载失败，请稍后重试。',
      isCached: false
    };
  }

  private toViewState(response: ProfileResponse, isCached: boolean): ProfileViewState {
    return {
      userId: response.profile?.userId ?? '',
      profileVersion: response.profileVersion,
      goal: response.profile?.goal ?? '',
      mastery: response.mastery,
      history: response.history,
      evidence: response.evidence,
      errorMessage: '',
      isCached: isCached
    };
  }
}
