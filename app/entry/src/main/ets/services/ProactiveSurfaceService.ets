import { common, wantAgent } from '@kit.AbilityKit';
import notificationManager from '@ohos.notificationManager';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AgentApiClient } from '../api/AgentApiClient';
import { ProactiveResponse } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { appState } from '../data/AppState';
import { ProactiveViewModel } from '../viewmodels/ProactiveViewModel';
import { ProactiveSettingsStore } from './ProactiveSettingsStore';
import { LearningCardService } from './LearningCardService';

const DOMAIN: number = 0x5A01;
const TAG: string = 'ProactiveSurface';

/** Refreshes every visible proactive surface after a learning-state event. */
export class ProactiveSurfaceService {
  static async refresh(context: common.UIAbilityContext, foreground: boolean): Promise<void> {
    if (foreground || !ProactiveSettingsStore.isEnabled()) return;
    const recentSessions = appState.getFocusSummary().recentSessions;
    const lastStudyAt: string | undefined = recentSessions.length > 0 ? recentSessions[0].endedAt : undefined;
    const request = ProactiveViewModel.buildRequest(
      appState.currentUser.userId,
      appState.getHighPriorityCourse()?.exam.daysLeft ?? 30,
      false,
      appState.activeFocusTask !== null && appState.focusResultDraft === null,
      lastStudyAt
    );
    const result = await AgentApiClient.getProactiveDecision(request);
    if (!result.ok) {
      const failure: ApiFailure = result as ApiFailure;
      hilog.warn(DOMAIN, TAG, '%{public}s', `Decision request failed: ${failure.error.code}`);
      return;
    }
    const decision: ProactiveResponse = result.data;
    // The same Agent decision drives both proactive surfaces. Updating the desktop card does not
    // depend on notification permission or shouldNotify; only system notification delivery does.
    await LearningCardService.saveDecision(context, decision);
    if (decision.shouldNotify && decision.channel === 'reminder') {
      await ProactiveSurfaceService.publish(context, decision);
    }
  }

  private static async publish(context: common.UIAbilityContext, decision: ProactiveResponse): Promise<void> {
    if (!ProactiveSettingsStore.isEnabled()) return;
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        hilog.warn(DOMAIN, TAG, '%{public}s', 'Notification permission is disabled; skip publish.');
        return;
      }
      const request: notificationManager.NotificationRequest = { id: 20260918,
        // SDK 依据（notificationContent.d.ts:473-489）：
        //   contentType            @deprecated since 11
        //                          @useinstead NotificationContent#notificationContentType
        // 所以这里用 notificationContentType；取值 0 = NOTIFICATION_CONTENT_BASIC_TEXT
        // （枚举 ContentType 的第一个成员，见 @ohos.notificationManager.d.ts:1189）。
        content: { notificationContentType: 0,
          normal: { title: decision.title, text: decision.body, additionalText: '知学 Mate Agent 主动提醒' } },
        wantAgent: await wantAgent.getWantAgent({
          wants: [{
            bundleName: 'com.zhixue.mate',
            abilityName: 'EntryAbility',
            parameters: {
              source: 'learning_card',
              taskName: decision.cardData.taskName,
              durationMinutes: decision.cardData.durationMinutes
            }
          }],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: 20260918,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        })
      };
      await notificationManager.publish(request);
      hilog.info(DOMAIN, TAG, '%{public}s', 'Proactive notification published.');
    } catch (error) {
      hilog.error(DOMAIN, TAG, '%{public}s', `Notification publish failed: ${JSON.stringify(error)}`);
    }
  }

  static async requestPermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      if (await notificationManager.isNotificationEnabled()) return true;
      await notificationManager.requestEnableNotification(context);
      return await notificationManager.isNotificationEnabled();
    } catch (error) {
      hilog.error(DOMAIN, TAG, '%{public}s', `Notification permission failed: ${JSON.stringify(error)}`);
      return false;
    }
  }
}
