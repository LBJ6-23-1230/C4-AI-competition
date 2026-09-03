import { AgentHistoryItem, AgentRequest, AgentResponse, ChatAction, ChatCard, ChatCardType, ChatIntent, ChatMessage } from '../models/ChatModels';
import { http } from '@kit.NetworkKit';
import { appState } from '../data/AppState';

// ===== 配置: 后端地址 =====
const AGENT_API_BASE: string = 'http://10.0.2.2:5000';

interface IntentRule {
  intent: ChatIntent;
  keywords: string[];
}

const INTENT_RULES: IntentRule[] = [
  { intent: 'match_partner', keywords: ['搭子', '匹配', '伙伴', '搭档', '一起学', '组队', '找个人'] },
  { intent: 'analyze_wrong', keywords: ['这道题', '错题', '为什么错', '图片', '拍照', '错了', '不会做'] },
  { intent: 'update_profile', keywords: ['添加', '设置', '修改', '更新', '删除', '记录', '我掌握了', '学会了'] },
  { intent: 'query_tasks', keywords: ['任务', '作业', 'ddl', '待办', '要交', '有什么', '安排'] },
  { intent: 'get_suggestion', keywords: ['建议', '推荐', '学什么', '计划', '复习', '优先', '今天'] },
  { intent: 'analyze_weakness', keywords: ['薄弱', '短板', '诊断', '弱', '查漏补缺', '哪里不好', '没掌握'] },
];

export class AgentBridge {
  static matchIntentLocal(message: string): ChatIntent {
    const normalized: string = message.trim().toLowerCase();
    for (let i: number = 0; i < INTENT_RULES.length; i++) {
      const rule: IntentRule = INTENT_RULES[i];
      for (let j: number = 0; j < rule.keywords.length; j++) {
        if (normalized.indexOf(rule.keywords[j]) !== -1) {
          return rule.intent;
        }
      }
    }
    return 'get_suggestion';
  }

  static buildRequest(message: string, image: string | undefined, history: ChatMessage[]): AgentRequest {
    const latestHistory: ChatMessage[] = history
      .filter((item: ChatMessage) => item.status === 'done')
      .slice(-20);
    const mappedHistory: AgentHistoryItem[] = [];
    for (let i: number = 0; i < latestHistory.length; i++) {
      const item: ChatMessage = latestHistory[i];
      mappedHistory.push({ role: item.role, text: item.text });
    }

    const request: AgentRequest = {
      message: message,
      image: image,
      history: mappedHistory
    };
    return request;
  }

  static buildRequestBody(message: string, image: string, history: AgentHistoryItem[]): string {
    // 单独序列化 user_data，避免 inline object literal 触发 ArkTS 编译错误
    const userDataObj: Record<string, Object> = {};
    userDataObj['courses'] = appState.courses;
    userDataObj['homeworkDDLs'] = appState.homeworkDDLs;
    userDataObj['isDataImported'] = appState.isDataImported;
    const userDataStr: string = JSON.stringify(userDataObj);

    const parts: string[] = [];
    parts.push('"message":' + JSON.stringify(message));
    parts.push('"image":' + JSON.stringify(image));
    parts.push('"history":' + JSON.stringify(history));
    parts.push('"user_data":' + userDataStr);
    return '{' + parts.join(',') + '}';
  }

  static async callAgent(
    message: string,
    image: string | undefined,
    history: ChatMessage[]
  ): Promise<AgentResponse> {
    const request: AgentRequest = AgentBridge.buildRequest(message, image, history);
    const imageStr: string = image ?? '';

    try {
      const requestBody: string = AgentBridge.buildRequestBody(request.message, imageStr, request.history);

      const httpRequest: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: requestBody,
        connectTimeout: 30000,
        readTimeout: 60000
      };
      const httpResponse: http.HttpResponse =
        await http.createHttp().request(AGENT_API_BASE + '/api/agent/chat', httpRequest);

      if (httpResponse.responseCode === 200) {
        const resultStr: string = httpResponse.result as string;
        const data: Record<string, Object> = JSON.parse(resultStr) as Record<string, Object>;
        return AgentBridge.parseResponse(data);
      }
      console.warn('[AgentBridge] Backend unavailable, using local demo');
      return AgentBridge.createDemoResponse(message, image);
    } catch (err) {
      console.warn('[AgentBridge] Network error, using local demo');
      return AgentBridge.createDemoResponse(message, image);
    }
  }

  static parseResponse(data: Record<string, Object>): AgentResponse {
    const reply: string = (data['reply'] as string) || 'received, thinking...';
    const intent: string = (data['intent'] as string) || 'free_chat';
    const cardObj: Object | undefined = data['card'] as Object | undefined;

    let card: ChatCard | undefined = undefined;
    if (cardObj !== undefined && cardObj !== null) {
      card = AgentBridge.parseCard(cardObj as Record<string, Object>);
    }

    return { reply: reply, intent: intent, card: card };
  }

  static parseCard(cardObj: Record<string, Object>): ChatCard {
    const cardType: string = (cardObj['type'] as string) || 'suggestion';
    const title: string = (cardObj['title'] as string) || '';
    const summary: string = (cardObj['summary'] as string) || '';
    const targetPage: string = (cardObj['targetPage'] as string) || '';
    const dataMap: Map<string, string> = new Map<string, string>();

    // 给卡片加默认操作按钮
    const actionLabel: string = AgentBridge.getActionLabel(cardType);
    const action: ChatAction = { label: actionLabel, targetPage: targetPage };
    const actions: ChatAction[] = [action];

    return { type: cardType as ChatCardType, title: title, summary: summary, targetPage: targetPage, data: dataMap, actions: actions };
  }

  static getActionLabel(cardType: string): string {
    if (cardType === 'weakness') { return '查看薄弱诊断'; }
    if (cardType === 'partner') { return '查看搭子详情'; }
    if (cardType === 'tasks') { return '查看任务清单'; }
    if (cardType === 'wrong') { return '查看错题分析'; }
    return '查看详情';
  }

  static createDemoResponse(message: string, image: string | undefined): AgentResponse {
    const intent: ChatIntent = AgentBridge.matchIntentLocal(message);

    if (image !== undefined && image.length > 0) {
      return {
        reply: '图片已收到。你可以进入错题分析页，查看识别出的知识点、错误类型和补强建议。',
        intent: 'analyze_wrong',
        card: AgentBridge.createLocalCard('wrong', '错题分析', '基于题目内容识别知识点和错误原因。', 'pages/WrongQuestion')
      };
    }

    const replyMap: Map<ChatIntent, string> = new Map<ChatIntent, string>();
    replyMap.set('query_tasks', '我先帮你列出当前的任务。LLM正在连接中，稍后会有更智能的分析。');
    replyMap.set('analyze_weakness', '你的薄弱点分析在知识画像页面有展示。LLM接入后我会动态分析错题规律。');
    replyMap.set('get_suggestion', '我根据你的课程紧迫度给你推荐学习任务。LLM就绪后推荐会更个性化。');
    replyMap.set('match_partner', '搭子匹配功能已就绪！你可以去搭子页面查看匹配结果。');
    replyMap.set('analyze_wrong', '请描述一下这道题：题目内容、你的答案、正确答案。我帮你分析。');
    replyMap.set('update_profile', '好的，我帮你更新信息。');
    replyMap.set('free_chat', '你可以直接问我要建议、查薄弱点、匹配搭子，或者上传错题让我分析～');

    const defaultReply: string = 'Ask me about study suggestions, weak points, partner matching, or upload wrong questions!';
    const foundReply: string | undefined = replyMap.get(intent);

    return {
      reply: foundReply !== undefined ? foundReply : defaultReply,
      intent: intent,
      card: AgentBridge.createLocalCardForIntent(intent)
    };
  }

  /** Local fallback uses the same navigation cards as the real Agent response. */
  static createLocalCardForIntent(intent: ChatIntent): ChatCard | undefined {
    if (intent === 'analyze_weakness') {
      return AgentBridge.createLocalCard('weakness', '知识画像', '查看当前薄弱知识点、掌握度和学习证据。', 'pages/StudyTags');
    }
    if (intent === 'analyze_wrong') {
      return AgentBridge.createLocalCard('wrong', '错题分析', '上传或选择一道错题，获取错误原因和补强建议。', 'pages/WrongQuestion');
    }
    if (intent === 'query_tasks' || intent === 'get_suggestion') {
      return AgentBridge.createLocalCard('tasks', '学习计划', '查看近期学习任务和优先级安排。', 'pages/StudyPlan');
    }
    if (intent === 'match_partner') {
      return AgentBridge.createLocalCard('partner', '学习搭子', '查看基于课程、目标和时间的匹配结果。', 'pages/PartnerMatch');
    }
    return undefined;
  }

  static createLocalCard(type: ChatCardType, title: string, summary: string, targetPage: string): ChatCard {
    const action: ChatAction = { label: AgentBridge.getActionLabel(type), targetPage: targetPage };
    return { type: type, title: title, summary: summary, targetPage: targetPage, data: new Map<string, string>(), actions: [action] };
  }
}
