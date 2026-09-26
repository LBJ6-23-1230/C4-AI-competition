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
  static buildRequest(userId: string, daysLeft: number | undefined, foreground: boolean,
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
        focusSessionActive: focusSessionActive
      }
    };
    // ⚠️ **只有真的知道考试倒计时时才下发 `daysLeft`**。
    //
    // 原实现无条件下发，而调用方在"没有课程 / 没有考试日期"时用 `?? 30` 编了一个
    // 30 天 —— 后端据此算出「考试剩 30 天（紧迫度贡献 0.000）」写进卡片文案，
    // 与同一 App 计划页显示的后端口径（5 天 → 0.83）**互相矛盾**，
    // 且紧迫度这一因子在访客演示里被彻底打成 0。
    //
    // 后端 `has_exam_signal = ("daysLeft" in context) and ("masteryScore" in context)`，
    // 不下发即如实跳过考试类判断（不编造倒计时）。
    if (daysLeft !== undefined && Number.isFinite(daysLeft)) {
      request.context.daysLeft = Math.max(0, Math.floor(daysLeft));
    }
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

  async load(userId: string, daysLeft: number | undefined, foreground: boolean = true,
    focusSessionActive: boolean = false, lastStudyAt?: string): Promise<ProactiveViewState> {
    const request: ProactiveRequest = ProactiveViewModel.buildRequest(
      userId, daysLeft, foreground, focusSessionActive, lastStudyAt);
    const result = await AgentApiClient.getProactiveDecision(request);
    if (result.ok) return { decision: result.data, errorMessage: '' };
    return { decision: null, errorMessage: (result as ApiFailure).error.message };
  }
}
