import { AgentApiClient } from '../api/AgentApiClient';
import { PendingTaskSignal, ProactiveRequest, ProactiveResponse, ProfileResponse } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { ClientCache } from '../cache/ClientCache';
import { appState } from '../data/AppState';
import { HomeworkDDL } from '../models/AgentModels';

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
    const urgentDDLs: HomeworkDDL[] = appState.getUrgentDDLs();
    if (urgentDDLs.length > 0) {
      const pendingTasks: PendingTaskSignal[] = [];
      for (let index: number = 0; index < urgentDDLs.length; index++) {
        const ddl: HomeworkDDL = urgentDDLs[index];
        pendingTasks.push({
          taskId: ddl.id,
          title: ddl.title,
          status: 'pending',
          started: false,
          daysLeft: ddl.daysLeft
        });
      }
      request.context.pendingTasks = pendingTasks;
    }
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
