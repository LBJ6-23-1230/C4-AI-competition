import { AgentHistoryItem, AgentRequest, AgentResponse, ChatAction, ChatCard, ChatCardType, ChatIntent, ChatMessage } from '../models/ChatModels';
import { http } from '@kit.NetworkKit';
import { appState } from '../data/AppState';
import { AgentApiClient, ApiClientConfig } from '../api/AgentApiClient';
import { API_CONTRACT_VERSION } from '../api/ApiModels';

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
    const apiConfig: ApiClientConfig = AgentApiClient.getConfig();

    // Fixture 是完整的离线演示模式，不应先等待真实后端连接超时。
    if (apiConfig.useFixture) {
      return AgentBridge.createDemoResponse(message, image);
    }

    const httpRequestInstance: http.HttpRequest = http.createHttp();
    try {
      const requestBody: string = AgentBridge.buildRequestBody(request.message, imageStr, request.history);

      const httpRequest: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'X-API-Contract-Version': API_CONTRACT_VERSION
        },
        extraData: requestBody,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: apiConfig.timeoutMs,
        readTimeout: apiConfig.timeoutMs
      };
      const httpResponse: http.HttpResponse =
        await httpRequestInstance.request(apiConfig.baseUrl + '/api/agent/chat', httpRequest);

      if (httpResponse.responseCode >= 200 && httpResponse.responseCode < 300) {
        const resultStr: string = (httpResponse.result as string).trim();
        if (resultStr.length === 0) {
          throw new Error('服务未返回可解析的数据。');
        }
        try {
          const data: Record<string, Object> = JSON.parse(resultStr) as Record<string, Object>;
          return AgentBridge.parseResponse(data);
        } catch (parseError) {
          throw new Error('服务返回的数据格式不正确，请检查聊天接口响应。');
        }
      }
      const serverFailure = AgentApiClient.parseServerError(httpResponse.result as string, httpResponse.responseCode);
      throw new Error(`服务请求失败：${serverFailure.error.message}`);
    } catch (err) {
      const detail: string = err instanceof Error ? err.message : '';
      if (detail.startsWith('服务')) {
        throw new Error(detail);
      }
      throw new Error('连接超时或网络不可用，请检查服务地址后重试。');
    } finally {
      httpRequestInstance.destroy();
    }
  }

  static parseResponse(data: Record<string, Object>): AgentResponse {
    const reply: string = AgentBridge.requiredString(data, 'reply');
    const intent: string = AgentBridge.normalizeIntent(
      AgentBridge.requiredString(data, 'intent'));
    const cardObj: Object | undefined = data['card'] as Object | undefined;
    const rawLlmUsed: Object | undefined = data['llmUsed'] as Object | undefined;

    let card: ChatCard | undefined = undefined;
    if (cardObj !== undefined && cardObj !== null) {
      if (typeof cardObj !== 'object' || Array.isArray(cardObj)) {
        throw new Error('card must be an object.');
      }
      card = AgentBridge.parseCard(cardObj as Record<string, Object>);
    }

    let llmUsed: boolean | undefined = undefined;
    if (rawLlmUsed !== undefined && rawLlmUsed !== null) {
      if (typeof rawLlmUsed !== 'boolean') {
        throw new Error('llmUsed must be a boolean.');
      }
      llmUsed = rawLlmUsed as boolean;
    }

    return { reply: reply, intent: intent, card: card, llmUsed: llmUsed };
  }

  static parseCard(cardObj: Record<string, Object>): ChatCard {
    const rawCardType: string = AgentBridge.requiredString(cardObj, 'type');
    const cardType: ChatCardType = AgentBridge.normalizeCardType(rawCardType);
    const title: string = AgentBridge.stringField(cardObj, 'title');
    const summary: string = AgentBridge.stringField(cardObj, 'summary');
    const rawTargetPage: string = AgentBridge.requiredString(cardObj, 'targetPage');
    const targetPage: string = AgentBridge.safeTargetPage(cardType, rawTargetPage);
    const dataMap: Map<string, string> = new Map<string, string>();

    // 给卡片加默认操作按钮
    const backendActionLabel: string = AgentBridge.stringField(cardObj, 'actionLabel');
    const actionLabel: string = backendActionLabel.length > 0 ? backendActionLabel : AgentBridge.getActionLabel(cardType);
    const action: ChatAction = { label: actionLabel, targetPage: targetPage };
    const actions: ChatAction[] = [action];

    return { type: cardType, title: title, summary: summary, targetPage: targetPage, data: dataMap, actions: actions };
  }

  private static requiredString(data: Record<string, Object>, key: string): string {
    const value: Object | undefined = data[key] as Object | undefined;
    if (typeof value !== 'string' || (value as string).trim().length === 0) {
      throw new Error(`${key} must be a non-empty string.`);
    }
    return value as string;
  }

  private static stringField(data: Record<string, Object>, key: string): string {
    const value: Object | undefined = data[key] as Object | undefined;
    if (value === undefined || value === null) {
      return '';
    }
    if (typeof value !== 'string') {
      throw new Error(`${key} must be a string.`);
    }
    return value as string;
  }

  /**
   * 把服务端返回的 intent 收敛到 `ChatIntent` 白名单内。
   *
   * 为什么需要：`AgentResponse.intent` 是 `string`（后端可能返回契约之外的值），
   * 而下游 `replyMap` / `createLocalCardForIntent` 全部按枚举做映射。
   * 不做收敛时，任何未列举的取值都会**静默 miss** ——
   * 表现为"回复有了但没有「接下来」卡"，且不报错、难定位。
   * 兜底为 `unknown`（而非 `get_suggestion`）是刻意的：
   * `unknown` 会被渲染成中性的"继续提问"卡，
   * 而误判成 `get_suggestion` 会给出**错误指向具体学习建议页**的卡。
   */
  private static normalizeIntent(intent: string): ChatIntent {
    if (intent === 'query_tasks' || intent === 'analyze_weakness' ||
      intent === 'get_suggestion' || intent === 'match_partner' ||
      intent === 'analyze_wrong' || intent === 'update_profile' ||
      intent === 'free_chat' || intent === 'unknown') {
      return intent as ChatIntent;
    }
    return 'unknown';
  }

  private static normalizeCardType(cardType: string): ChatCardType {
    if (cardType === 'analyze_weakness') return 'weakness';
    if (cardType === 'match_partner') return 'partner';
    if (cardType === 'query_tasks') return 'tasks';
    if (cardType === 'analyze_wrong') return 'wrong';
    if (cardType === 'get_suggestion' || cardType === 'update_profile') return 'suggestion';
    if (cardType === 'weakness' || cardType === 'partner' || cardType === 'tasks' ||
      cardType === 'wrong' || cardType === 'suggestion') {
      return cardType as ChatCardType;
    }
    return 'suggestion';
  }

  private static safeTargetPage(cardType: ChatCardType, targetPage: string): string {
    const safePages: string[] = [
      'pages/Index', 'pages/StudySuggestion', 'pages/WrongQuestion', 'pages/StudyTags',
      'pages/ExercisePractice', 'pages/AgentTrace', 'pages/PartnerMatch', 'pages/StudyPlan',
      'pages/ReviewSummary', 'pages/FocusSetup'
    ];
    if (safePages.indexOf(targetPage) >= 0) {
      return targetPage;
    }
    if (cardType === 'weakness') return 'pages/StudyTags';
    if (cardType === 'partner') return 'pages/PartnerMatch';
    if (cardType === 'wrong') return 'pages/WrongQuestion';
    if (cardType === 'tasks') return 'pages/StudyPlan';
    return 'pages/StudySuggestion';
  }

  /** 卡片底部按钮文案：统一说"查看哪个页面"，与 chip 名称同一套口径。 */
  static getActionLabel(cardType: string): string {
    if (cardType === 'weakness') { return '查看学情画像'; }
    if (cardType === 'partner') { return '查看学习搭子'; }
    if (cardType === 'tasks') { return '查看今日任务'; }
    if (cardType === 'wrong') { return '查看错题诊断'; }
    return '查看今日学习建议';
  }

  static createDemoResponse(message: string, image: string | undefined): AgentResponse {
    const intent: ChatIntent = AgentBridge.matchIntentLocal(message);

    if (image !== undefined && image.length > 0) {
      return {
        reply: '图片已收到。你可以进入错题分析页，查看识别出的知识点、错误类型和补强建议。',
        intent: 'analyze_wrong',
        card: AgentBridge.createLocalCard('wrong', '错题分析', '基于题目内容识别知识点和错误原因。', 'pages/WrongQuestion'),
        llmUsed: false
      };
    }

    const replyMap: Map<ChatIntent, string> = new Map<ChatIntent, string>();
    replyMap.set('query_tasks', '我已按当前课程与作业 DDL 整理出今日任务，可以打开学习计划查看优先级。');
    replyMap.set('analyze_weakness', '我已读取当前学情画像，你可以查看薄弱知识点、掌握度和学习证据。');
    replyMap.set('get_suggestion', '我已按课程紧迫度、近期复习状态与薄弱点算好今日学习建议，先从最高优先级任务开始。');
    replyMap.set('match_partner', '我已按课程、目标、知识互补与空闲时间完成学习搭子匹配，可以查看匹配因子明细。');
    replyMap.set('analyze_wrong', '请上传或选择一道错题，我会展示知识点、错误原因和补强建议。');
    replyMap.set('update_profile', '离线演示下画像由诊断练习自动更新：去「练习智能体」做一组专项题，掌握度会随之变化。');
    replyMap.set('free_chat', '你可以问我今日学习建议、学情画像、今日任务或学习搭子，也可以上传错题。');
    // ⚠️ `unknown` 是后端 `MainAgentPrompt.txt` 规定的**合法兜底意图**
    //（不属于 6 类具体意图时返回 {"intent":"unknown"}）。
    // 前端原先没有这个取值，导致真实模型返回 unknown 时 replyMap 全部 miss。
    replyMap.set('unknown', '你可以问我今日学习建议、学情画像、今日任务或学习搭子，也可以上传错题。');

    const defaultReply: string = '你可以问我今日学习建议、学情画像、今日任务或学习搭子。';
    const foundReply: string | undefined = replyMap.get(intent);

    return {
      reply: foundReply !== undefined ? foundReply : defaultReply,
      intent: intent,
      card: AgentBridge.createLocalCardForIntent(intent),
      llmUsed: false
    };
  }

  /**
   * 离线 Fixture 模式下，每个意图各自对应一张卡片。
   *
   * ⚠️ **一个意图一张卡，一个按钮一个页面**。
   *
   * 修正来源：原实现把 `get_suggestion` 与 `query_tasks` 合并进同一个分支
   * （`intent === 'query_tasks' || intent === 'get_suggestion'`，都返回
   * "学习计划" → `pages/StudyPlan`），而 `update_profile` 直接落到末尾
   * `return undefined` ——**没有任何卡片**。后果是：
   *   · 顶部"今日建议"和"查任务"两个按钮点出**同一个结果**；
   *   · "更新信息"点下去**什么都不给**。
   * 六个按钮有三个是失真的，用户自然会觉得"名字和功能对不上"。
   *
   * 现在按后端 `chat_llm.INTENT_CARDS` 的权威口径逐个对齐：
   *   get_suggestion → 学习建议   → pages/StudySuggestion
   *   analyze_wrong  → 错题分析   → pages/WrongQuestion
   *   analyze_weakness → 学情画像 → pages/StudyTags
   *   match_partner  → 学习搭子   → pages/PartnerMatch
   *   query_tasks    → 今日任务   → pages/StudyPlan
   *   update_profile → 学习画像   → pages/StudyTags
   *
   * 卡片标题一律用**页面标题**，而不是内部术语，保证"按钮名 = 落地页名"。
   */
  static createLocalCardForIntent(intent: ChatIntent): ChatCard | undefined {
    if (intent === 'get_suggestion') {
      return AgentBridge.createLocalCard('suggestion', '今日学习建议',
        '按课程紧迫度、近期复习状态与薄弱点算出的下一步动作。', 'pages/StudySuggestion');
    }
    if (intent === 'analyze_wrong') {
      return AgentBridge.createLocalCard('wrong', '错题诊断',
        '上传或选择一道错题，获取错误原因和补强建议。', 'pages/WrongQuestion');
    }
    if (intent === 'analyze_weakness') {
      return AgentBridge.createLocalCard('weakness', '学情画像',
        '查看当前薄弱知识点、掌握度和学习证据。', 'pages/StudyTags');
    }
    if (intent === 'match_partner') {
      return AgentBridge.createLocalCard('partner', '学习搭子',
        '查看基于课程、目标和时间的匹配结果。', 'pages/PartnerMatch');
    }
    if (intent === 'query_tasks') {
      return AgentBridge.createLocalCard('tasks', '今日任务',
        '查看近期学习任务和优先级安排。', 'pages/StudyPlan');
    }
    if (intent === 'update_profile') {
      return AgentBridge.createLocalCard('weakness', '学习画像',
        '更新掌握情况后，画像与后续推荐会同步重算。', 'pages/StudyTags');
    }
    if (intent === 'free_chat' || intent === 'unknown') {
      // 兜底意图也必须有"接下来"，否则用户说完一句无法归类的话后**无路可走**。
      // 这与本工程"每个终点页都有「接下来」卡"的原则一致。
      // 指向对话页自身即可（留在原地继续问），不引入新的落地页。
      return AgentBridge.createLocalCard('suggestion', '继续提问',
        '可以问我今日学习建议、学情画像、今日任务或学习搭子，也可以上传错题。', 'pages/ChatMain');
    }
    return undefined;
  }

  static createLocalCard(type: ChatCardType, title: string, summary: string, targetPage: string): ChatCard {
    const action: ChatAction = { label: AgentBridge.getActionLabel(type), targetPage: targetPage };
    return { type: type, title: title, summary: summary, targetPage: targetPage, data: new Map<string, string>(), actions: [action] };
  }
}
