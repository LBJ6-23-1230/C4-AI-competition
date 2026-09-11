import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { WorkflowResponse } from '../api/ApiModels';
import { ClientCache } from './ClientCache';

/** Persists only workflow identity; live status is fetched again after restart. */
export class WorkflowSessionStore {
  private static readonly STORE_NAME: string = 'workflow_session';
  private static readonly KEY_SESSION_ID: string = 'session_id';
  private static readonly KEY_TRACE_ID: string = 'trace_id';
  private static readonly KEY_STATUS: string = 'status';
  private static readonly KEY_CURRENT_STEP: string = 'current_step';
  private static readonly KEY_NEXT_ACTION: string = 'next_action';

  static restore(context: common.UIAbilityContext): boolean {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: WorkflowSessionStore.STORE_NAME
      });
      const sessionId: string = store.getSync(WorkflowSessionStore.KEY_SESSION_ID, '') as string;
      const traceId: string = store.getSync(WorkflowSessionStore.KEY_TRACE_ID, '') as string;
      if (sessionId.length === 0 || traceId.length === 0) {
        return true;
      }
      ClientCache.cacheWorkflow({
        sessionId: sessionId,
        traceId: traceId,
        status: store.getSync(WorkflowSessionStore.KEY_STATUS, 'running') as 'running' | 'completed' | 'failed' | 'fallback',
        currentStep: store.getSync(WorkflowSessionStore.KEY_CURRENT_STEP, '') as string,
        nextAction: store.getSync(WorkflowSessionStore.KEY_NEXT_ACTION, '') as string
      });
      ClientCache.invalidateWorkflowStatus();
      return true;
    } catch (error) {
      return false;
    }
  }

  static save(context: common.UIAbilityContext, workflow: WorkflowResponse): boolean {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: WorkflowSessionStore.STORE_NAME
      });
      store.putSync(WorkflowSessionStore.KEY_SESSION_ID, workflow.sessionId);
      store.putSync(WorkflowSessionStore.KEY_TRACE_ID, workflow.traceId);
      store.putSync(WorkflowSessionStore.KEY_STATUS, workflow.status);
      store.putSync(WorkflowSessionStore.KEY_CURRENT_STEP, workflow.currentStep);
      store.putSync(WorkflowSessionStore.KEY_NEXT_ACTION, workflow.nextAction);
      store.flushSync();
      return true;
    } catch (error) {
      return false;
    }
  }

  static clear(context: common.UIAbilityContext): boolean {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: WorkflowSessionStore.STORE_NAME
      });
      store.clearSync();
      store.flushSync();
      ClientCache.invalidateWorkflow();
      return true;
    } catch (error) {
      ClientCache.invalidateWorkflow();
      return false;
    }
  }
}
