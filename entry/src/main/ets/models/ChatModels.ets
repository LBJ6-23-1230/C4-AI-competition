export type ChatRole = 'user' | 'agent';
export type ChatStatus = 'sending' | 'done' | 'error';
export type ChatIntent = 'query_tasks' | 'analyze_weakness' | 'get_suggestion'
  | 'match_partner' | 'analyze_wrong' | 'update_profile' | 'free_chat';
export type ChatCardType = 'suggestion' | 'weakness' | 'partner' | 'tasks' | 'wrong';

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
}

export interface IntentChip {
  intent: ChatIntent;
  label: string;
  prompt: string;
}
