import { common } from '@kit.AbilityKit';
import notificationManager from '@ohos.notificationManager';
import { AgentApiClient } from '../api/AgentApiClient';
import { ProactiveResponse } from '../api/ApiModels';
import { appState } from '../data/AppState';
import { ProactiveSettingsStore } from './ProactiveSettingsStore';

/** Refreshes every visible proactive surface after a learning-state event. */
export class ProactiveSurfaceService {
  static async refresh(context: common.UIAbilityContext, foreground: boolean): Promise<void> {
    if (!foreground && !ProactiveSettingsStore.isEnabled()) return;
    const result = await AgentApiClient.getProactiveDecision({
      userId: appState.currentUser.userId,
      context: { now: new Date().toISOString(), foreground: foreground, focusSessionActive: false,
        masteryScore: 58, errorIntensity: 67,
        daysLeft: Math.max(0, appState.getHighPriorityCourse().exam.daysLeft), importance: 90 }
    });
    if (!result.ok) return;
    const decision: ProactiveResponse = result.data;
    if (decision.shouldNotify && decision.channel === 'reminder') {
      await ProactiveSurfaceService.publish(context, decision);
    }
  }

  private static async publish(context: common.UIAbilityContext, decision: ProactiveResponse): Promise<void> {
    if (!ProactiveSettingsStore.isEnabled()) return;
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      if (!enabled) await notificationManager.requestEnableNotification(context);
      const request: notificationManager.NotificationRequest = { id: 20260918,
        // The SDK's cross-platform declaration currently exposes the manager enum but
        // types NotificationContent against the legacy enum. Both define basic text as 0.
        content: { contentType: 0,
          normal: { title: decision.title, text: decision.body, additionalText: '知学 Mate Agent 主动提醒' } }
      };
      await notificationManager.publish(request);
    } catch (error) { }
  }
}
