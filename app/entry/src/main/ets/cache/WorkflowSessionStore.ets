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
  /**
   * 该会话属于哪个身份。
   *
   * ⚠️ 必须存：本类的 `restore()` 在 `EntryAbility.onCreate` 里、
   * `AuthStore.initialize()` **之前**执行，那一刻根本不知道用户是谁。
   * 不存归属就会出现"账号恢复出上一个游客的工作流"，提交练习时后端
   * 认不出这个 session → 404。
   */
  private static readonly KEY_USER_ID: string = 'user_id';

  static restore(context: common.UIAbilityContext): boolean {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: WorkflowSessionStore.STORE_NAME
      });
      const sessionId: string = store.getSync(WorkflowSessionStore.KEY_SESSION_ID, '') as string;
      const traceId: string = store.getSync(WorkflowSessionStore.KEY_TRACE_ID, '') as string;
      const userId: string = store.getSync(WorkflowSessionStore.KEY_USER_ID, '') as string;
      // 没有归属身份的历史数据（本次修复前写入的）一律不恢复：
      // 宁可这一轮重建工作流，也不能把别人的会话认成自己的。
      if (sessionId.length === 0 || traceId.length === 0 || userId.length === 0) {
        return true;
      }
      // 只**暂存**，不直接写 ClientCache —— 此时身份未知，
      // 由 `ClientCache.bindIdentity()` 认出身份后再采纳。
      ClientCache.stageRestoredWorkflow(userId, {
        sessionId: sessionId,
        traceId: traceId,
        status: store.getSync(WorkflowSessionStore.KEY_STATUS, 'running') as 'running' | 'completed' | 'failed' | 'fallback' | 'error',
        currentStep: store.getSync(WorkflowSessionStore.KEY_CURRENT_STEP, '') as string,
        nextAction: store.getSync(WorkflowSessionStore.KEY_NEXT_ACTION, '') as string
      });
      return true;
    } catch (error) {
      return false;
    }
  }

  static save(context: common.UIAbilityContext, workflow: WorkflowResponse, userId: string): boolean {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: WorkflowSessionStore.STORE_NAME
      });
      store.putSync(WorkflowSessionStore.KEY_SESSION_ID, workflow.sessionId);
      store.putSync(WorkflowSessionStore.KEY_TRACE_ID, workflow.traceId);
      store.putSync(WorkflowSessionStore.KEY_STATUS, workflow.status);
      store.putSync(WorkflowSessionStore.KEY_CURRENT_STEP, workflow.currentStep);
      store.putSync(WorkflowSessionStore.KEY_NEXT_ACTION, workflow.nextAction);
      store.putSync(WorkflowSessionStore.KEY_USER_ID, userId);
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
