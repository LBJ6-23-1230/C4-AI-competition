import { AgentHistoryItem, AgentRequest, AgentResponse, ChatAction, ChatCard, ChatCardType, ChatIntent, ChatMessage, WrongAnalysis } from '../models/ChatModels';
import { http } from '@kit.NetworkKit';
import { appState } from '../data/AppState';
import { AgentApiClient, ApiClientConfig } from '../api/AgentApiClient';
import { API_CONTRACT_VERSION } from '../api/ApiModels';
import { ApiDefaults } from '../api/ApiDefaults';
import { AuthStore } from '../api/AuthStore';

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

/**
 * 聊天接口错误的分类标记。
 *
 * ⚠️ 取值沿用 `api/ApiResult` 的 `ApiError.code` 与 `AgentApiClient` 既有的错误码口径，
 * 不新造一套：
 *   · `INVALID_RESPONSE` / `EMPTY_RESPONSE` —— HTTP 已经通了，但响应结构/内容不符合契约；
 *   · `HTTP_ERROR`                          —— 服务端返回的业务失败（4xx/5xx + 后端 message）；
 *   · 没有标记                              —— http 层抛出的真网络 / 超时异常。
 * 用法：`taggedError()` 拼出「码 + 分隔符 + 人话」，外层 catch 用 `errorCodeOf()` 取分类、
 * 用 `errorTextOf()` 剥掉码再展示，避免靠中文字符串前缀去猜。
 */
const CODE_INVALID_RESPONSE: string = 'INVALID_RESPONSE';
const CODE_EMPTY_RESPONSE: string = 'EMPTY_RESPONSE';
const CODE_HTTP_ERROR: string = 'HTTP_ERROR';
const CODE_SEPARATOR: string = '::';

/**
 * 聊天层读超时下限（毫秒）—— 与结构化接口的 `timeoutMs` **分开**。
 *
 * 修复的缺陷：「错题诊断」是**唯一会真的调大模型**的意图，实测后端
 * `analyze_wrong` 单次要 **10.6–11.3 秒**（`llmUsed=true`）；而 `AgentBridge`
 * 原先把聊天请求的 `readTimeout` 也设成 `ApiDefaults.DEFAULT_TIMEOUT_MS = 8000`，
 * 于是**请求必然在模型回答之前被本地掐断** → 落到下面那个兜底分支 →
 * 用户看到「连接超时或网络不可用，请检查服务地址后重试」。
 * 其他意图走确定性规则、2–3 毫秒就返回，所以**只有错题诊断会报这个错**。
 *
 * 取值必须 > 后端 `LLM_TIMEOUT_SECONDS`（默认 30）：后端最坏 30 秒才回，
 * 客户端要留出余量，否则又把可控的降级变成了本地超时。
 *
 * ⚠️ 只放宽 `readTimeout`，`connectTimeout` 仍用配置值 —— 连不上就该快速失败，
 * 不该让用户等 40 秒才知道地址写错了。
 */
const CHAT_MIN_READ_TIMEOUT_MS: number = ApiDefaults.LLM_BOUND_READ_TIMEOUT_MS;

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
    // 「过滤 sending 状态」这条既有逻辑保留：它是为了滤掉"思考中"占位气泡。
    const doneHistory: ChatMessage[] = history
      .filter((item: ChatMessage) => item.status === 'done');
    // 原缺陷：占位气泡滤掉了，但**本条 user 消息**（status 已是 done）留了下来，
    // 而它同时又是请求体的 `message` 字段 —— 同一条输入于是发了两遍，
    // 模型每轮都会看到重复问题。
    // 这里做兜底（调用方现在也已经改传"发送前"的历史快照）：
    // 若 history 末项与本条 message 同源（同为 user、文本一致），就把它剔除，
    // 它由 `message` 字段承载，不该再进 history。
    const lastIndex: number = doneHistory.length - 1;
    const echoOfCurrent: boolean = lastIndex >= 0 &&
      doneHistory[lastIndex].role === 'user' && doneHistory[lastIndex].text === message;
    const withoutEcho: ChatMessage[] = echoOfCurrent ? doneHistory.slice(0, lastIndex) : doneHistory;
    const latestHistory: ChatMessage[] = withoutEcho.slice(-20);
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
    // 显式带上身份：后端 `_chat_identity()` 的解析顺序是
    // 「已登录身份 > 显式 userId > 演示身份」。不带的话，**账号登录后
    // 的对话仍会被当成 demo-user 处理并落盘**（历史、错题、画像更新全串味）。
    parts.push('"userId":' + JSON.stringify(appState.currentUser.userId));
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

      const header: Record<string, string> = {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'X-API-Contract-Version': API_CONTRACT_VERSION
      };
      // 已登录时带上凭据，与 `AgentApiClient.request()` 完全一致。
      // 游客 / 离线演示不带 Authorization，后端按 demo-user 处理，演示基线不受影响。
      const token: string = AuthStore.getToken();
      if (token.length > 0) {
        header['Authorization'] = `Bearer ${token}`;
      }
      // 读超时取「配置值」与「聊天层下限」的较大者：用户若在「接口环境」里
      // 把超时调得比 40 秒还长，尊重用户的设置；默认的 8 秒则被抬到 40 秒。
      const readTimeoutMs: number = Math.max(apiConfig.timeoutMs, CHAT_MIN_READ_TIMEOUT_MS);
      const httpRequest: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: requestBody,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: apiConfig.timeoutMs,
        readTimeout: readTimeoutMs
      };
      const httpResponse: http.HttpResponse =
        await httpRequestInstance.request(apiConfig.baseUrl + '/api/agent/chat', httpRequest);

      if (httpResponse.responseCode >= 200 && httpResponse.responseCode < 300) {
        const resultStr: string = (httpResponse.result as string).trim();
        if (resultStr.length === 0) {
          // (a) 类：HTTP 200 但响应体是空的，属于响应不符合契约，不是连不上
          throw AgentBridge.taggedError(CODE_EMPTY_RESPONSE, '服务未返回可解析的数据。');
        }
        try {
          const data: Record<string, Object> = JSON.parse(resultStr) as Record<string, Object>;
          return AgentBridge.parseResponse(data);
        } catch (parseError) {
          // (a) 类：JSON 语法不对、或 parseResponse() 判定字段不符合契约
          //（如 `reply must be a non-empty string.`）。
          // 原缺陷：这里把具体原因压成一句"格式不正确"，外层再统一兜成
          //「连接超时或网络不可用」，用户据此去查网络，重试永远不会好。
          // 现在保留具体原因并打上分类标记，外层据此给出可区分的提示。
          const parseDetail: string = parseError instanceof Error ? parseError.message : '';
          const contractDetail: string = parseDetail.length > 0 ? parseDetail : '响应内容无法解析';
          throw AgentBridge.taggedError(CODE_INVALID_RESPONSE, `服务响应不符合接口约定：${contractDetail}`);
        }
      }
      // (b) 类：服务端返回了业务失败（HTTP 4xx/5xx + errorCode/message），原文带出便于定位
      const serverFailure = AgentApiClient.parseServerError(httpResponse.result as string, httpResponse.responseCode);
      throw AgentBridge.taggedError(CODE_HTTP_ERROR, `服务请求失败：${serverFailure.error.message}`);
    } catch (err) {
      // 原缺陷：这里只把以「服务」二字开头的错误原样抛出，其余一律替换成
      //「连接超时或网络不可用」—— 于是"HTTP 200 但结构不对"这类契约错误也会被
      // 说成网络问题：提示与真实原因不符，用户重试也不会好。
      // 现在按上面三类标记分别给提示（三句互不相同，便于一眼区分）：
      //   (a) 契约 / 解析不符：HTTP 已返回，重试无用，要去查响应结构
      //   (b) 服务端业务失败：保留后端文案
      //   (c) 无标记的异常：只有这一类才是真的网络 / 超时失败
      const detail: string = err instanceof Error ? err.message : '';
      const code: string = AgentBridge.errorCodeOf(detail);
      const reason: string = AgentBridge.errorTextOf(detail);
      if (code === CODE_INVALID_RESPONSE) {
        throw new Error(`${reason}（这不是网络问题，重试不会好转，请检查服务端返回结构）`);
      }
      if (code === CODE_EMPTY_RESPONSE) {
        throw new Error(`${reason}（这不是网络问题，请检查服务端是否真的返回了 JSON）`);
      }
      if (code.length > 0) {
        throw new Error(reason);
      }
      // 只有走到这里才是真的 http 层异常（连不上 / 超时 / 连接被中断）。
      // 措辞不再一味甩给"服务地址"：聊天层读超时已放宽到 40 秒，但若用户在
      // 「接口环境」里把它调得更小、或后端 `LLM_TIMEOUT_SECONDS` 被调大，
      // 依然可能撞上超时 —— 那属于"等得不够久"，不是地址写错了。
      throw new Error('请求超时或连不上后端服务。请确认「接口环境」里的服务地址可访问；'
        + '使用真实大模型时生成较慢，也可能需要重试一次。');
    } finally {
      httpRequestInstance.destroy();
    }
  }

  /**
   * 把分类码拼进 message：`CODE::人话`。
   * 用普通 Error 承载（与工程既有风格一致，不新引入错误类），
   * 外层 catch 靠码分类、展示前再剥掉码。
   */
  private static taggedError(code: string, message: string): Error {
    return new Error(`${code}${CODE_SEPARATOR}${message}`);
  }

  /** 取错误里的分类码；没有码说明是 http 层抛出的原始异常（只能按网络失败处理）。 */
  private static errorCodeOf(detail: string): string {
    const separator: number = detail.indexOf(CODE_SEPARATOR);
    return separator > 0 ? detail.substring(0, separator) : '';
  }

  /** 取剥掉分类码之后的人话部分。 */
  private static errorTextOf(detail: string): string {
    const separator: number = detail.indexOf(CODE_SEPARATOR);
    return separator > 0 ? detail.substring(separator + CODE_SEPARATOR.length) : detail;
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

    // `wrongAnalysis` 是可选字段：缺失 / 结构不对都只意味着"没识别出知识点"，
    // 不该让整条回复失败（老后端也没有这个字段）。
    let wrongAnalysis: WrongAnalysis | undefined = undefined;
    const rawWrong: Object | undefined = data['wrongAnalysis'] as Object | undefined;
    if (rawWrong !== undefined && rawWrong !== null && typeof rawWrong === 'object'
      && !Array.isArray(rawWrong)) {
      const record: Record<string, Object> = rawWrong as Record<string, Object>;
      const point: string = AgentBridge.stringField(record, 'knowledgePoint');
      const wrongType: string = AgentBridge.stringField(record, 'wrongType');
      if (point.length > 0 || wrongType.length > 0) {
        wrongAnalysis = { knowledgePoint: point, wrongType: wrongType };
      }
    }

    return { reply: reply, intent: intent, card: card, llmUsed: llmUsed,
      wrongAnalysis: wrongAnalysis };
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
    if (cardType === 'profile') return 'pages/StudyTags';
    if (cardType === 'partner') return 'pages/PartnerMatch';
    if (cardType === 'wrong') return 'pages/WrongQuestion';
    if (cardType === 'tasks') return 'pages/StudyPlan';
    return 'pages/StudySuggestion';
  }

  /** 卡片底部按钮文案：统一说"查看哪个页面"，与 chip 名称同一套口径。 */
  static getActionLabel(cardType: string): string {
    if (cardType === 'weakness') { return '查看学情画像'; }
    // 与 `weakness` 说不同的话 —— 这一步是"改完了回看"，不是"第一次去看"。
    if (cardType === 'profile') { return '查看更新后的画像'; }
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
      // 卡片类型从 `weakness` 改成 `profile`：原先两条意图共用同一个类型，
      // 标题、按钮文案、图标全部一样，用户实测反馈「学习画像和学情画像…
      // 点开之后跳转的界面是一样的」——从卡片上根本分不出刚才是"看"还是"改"。
      return AgentBridge.createLocalCard('profile', '学习画像已更新',
        '你说明的情况已按**真实练习记录**核对后写入学习档案；画像与后续推荐已按新数据重算。',
        'pages/StudyTags');
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
