import { AgentApiClient } from '../api/AgentApiClient';
import { LearningPlan } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { ClientCache } from '../cache/ClientCache';

export interface PlanViewState {
  plan: LearningPlan | null;
  errorMessage: string;
  isCached: boolean;
}

/** Reads the current plan from the contract API without creating plan data locally. */
export class PlanViewModel {
  async load(forceRefresh: boolean = false): Promise<PlanViewState> {
    const cached: LearningPlan | null = ClientCache.getCurrentPlan();
    if (!forceRefresh && cached !== null) {
      return { plan: cached, errorMessage: '', isCached: true };
    }

    const result = await AgentApiClient.getCurrentPlan();
    if (result.ok) {
      ClientCache.cacheCurrentPlan(result.data);
      return { plan: result.data, errorMessage: '', isCached: false };
    }

    const failure = result as ApiFailure;
    // ⚠️ 404 **不是"出错了"，而是"还没有计划"** —— 两者必须分开说。
    //
    // 这条区分是注册流程改动的直接后果：新注册的账号默认**不再预置**那份写死的
    // 二叉树起始计划（用户反馈「创建一个新账号最好不直接给出已经写死的数据，
    // 比如二叉树…否则会给用户一种虚假的感觉」）。于是「学习建议」「学习计划」等页
    // 首次打开必然拿到 404。原样把后端的英文 `current plan not found` 抛给用户，
    // 会让人以为 App 坏了 —— 而真实情况是"还没让 Agent 生成过计划"，
    // 下一步该去智能体页跑一次。这里如实说清，并给出可执行的下一步。
    if (failure.error.statusCode === 404 || failure.error.code === 'NOT_FOUND') {
      return {
        plan: null,
        errorMessage: '你还没有学习计划。到「我的智能体」里启动一次 Agent 会话，'
          + '或先做一轮诊断练习 —— 计划会由 Agent 按你的真实练习记录生成，'
          + '而不是预置一份示例数据。',
        isCached: false
      };
    }

    const detail: string = failure.error.message;
    if (cached !== null) {
      return { plan: cached, errorMessage: `${detail} 正在显示刚才获取的数据。`, isCached: true };
    }
    return { plan: null, errorMessage: detail, isCached: false };
  }
}
