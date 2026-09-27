export type ChatRole = 'user' | 'agent';
export type ChatStatus = 'sending' | 'done' | 'error';
export type ChatIntent = 'query_tasks' | 'analyze_weakness' | 'get_suggestion'
  | 'match_partner' | 'analyze_wrong' | 'update_profile' | 'free_chat' | 'unknown';
// `profile` 与 `weakness` 是**两个**类型，虽然它们都落到 `pages/StudyTags`：
//   · `weakness` = 「学情画像」——**看**掌握度与薄弱点；
//   · `profile`  = 「更新学习画像」——**改**画像之后回看结果。
// 原先二者共用 `weakness`，导致卡片标题/按钮文案被 `getActionLabel` 按同一个
// 类型映射成完全一样的字，用户实测反馈「学习画像和学情画像…点开之后跳转的界面
// 是一样的」，从卡片上根本分不出刚才是看还是改。类型分开才能各说各的话。
export type ChatCardType = 'suggestion' | 'weakness' | 'profile' | 'partner' | 'tasks' | 'wrong';

export interface ChatCard {
  type: ChatCardType;
  title: string;
  summary: string;
  targetPage: string;
  data: Map<string, string>;
  actions?: ChatAction[];
}

export interface ChatAction {
  label: string;
  targetPage: string;
}

export interface ChatHandoff {
  summary: string;
  nextPrompt: string;
  actionLabel: string;
  targetPage: string;
}

export interface ChatMessage {
  id: string;
  role: ChatRole;
  text: string;
  image?: string;
  card?: ChatCard;
  /** true = 大模型生成，false = 本地确定性规则兜底。 */
  llmUsed?: boolean;
  time: string;
  status: ChatStatus;
}

export interface AgentHistoryItem {
  role: ChatRole;
  text: string;
}

export interface AgentRequest {
  message: string;
  image?: string;
  history: AgentHistoryItem[];
}

export interface AgentResponse {
  reply: string;
  intent: string;
  card?: ChatCard;
  llmUsed?: boolean;
  /**
   * 仅 `analyze_wrong` 意图下可能非空：错题分析识别出的**结构化**知识点。
   *
   * 为什么需要它：知识点若只存在于回复的自然语言里，程序没法用 ——
   * 而「拍一道错题 → 针对这个知识点练 → 判分反馈」这条闭环需要把它带出去。
   * 识别不出时为空，**不要自己编一个知识点**。
   */
  wrongAnalysis?: WrongAnalysis;
}

/** 错题分析的结构化结果（后端 `wrongAnalysis`）。 */
export interface WrongAnalysis {
  knowledgePoint?: string;
  wrongType?: string;
}

export interface IntentChip {
  intent: ChatIntent;
  label: string;
  prompt: string;
}
