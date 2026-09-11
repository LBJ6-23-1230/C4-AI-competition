import { AgentApiClient } from '../api/AgentApiClient';
import { WorkflowCreateRequest, WorkflowResponse, WorkflowStatusResponse } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { ClientCache } from '../cache/ClientCache';

/** Owns the client-side identity and latest status of one backend workflow. */
export class WorkflowViewModel {
  private errorMessage: string = '';

  getErrorMessage(): string {
    return this.errorMessage;
  }

  getCurrentWorkflow(): WorkflowResponse | null {
    return ClientCache.getWorkflow();
  }

  async start(goal: string, userId: string): Promise<WorkflowResponse | null> {
    this.errorMessage = '';
    const request: WorkflowCreateRequest = {
      goal: goal.trim().length > 0 ? goal : '完成当前薄弱知识点诊断',
      userId: userId.trim().length > 0 ? userId : undefined,
      maxSteps: 5
    };
    const result = await AgentApiClient.createWorkflow(request);
    if (result.ok) {
      ClientCache.cacheWorkflow(result.data);
      ClientCache.invalidateWorkflowStatus();
      ClientCache.invalidateTrace();
      return result.data;
    }
    this.errorMessage = (result as ApiFailure).error.message;
    return null;
  }

  async refreshStatus(forceRefresh: boolean = false): Promise<WorkflowStatusResponse | null> {
    this.errorMessage = '';
    const workflow: WorkflowResponse | null = ClientCache.getWorkflow();
    if (workflow === null) {
      this.errorMessage = '当前还没有进行中的 Agent 会话。';
      return null;
    }
    const cached: WorkflowStatusResponse | null = ClientCache.getWorkflowStatus();
    if (!forceRefresh && cached !== null) {
      return cached;
    }
    const result = await AgentApiClient.getWorkflow(workflow.sessionId);
    if (result.ok) {
      ClientCache.cacheWorkflowStatus(result.data);
      return result.data;
    }
    this.errorMessage = (result as ApiFailure).error.message;
    return null;
  }
}
