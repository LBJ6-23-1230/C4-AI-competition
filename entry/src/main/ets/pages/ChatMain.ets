import router from '@ohos.router';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { appState } from '../data/AppState';
import { ChatAction, ChatCard, ChatHandoff, ChatMessage, IntentChip } from '../models/ChatModels';
import { AgentBridge } from '../services/AgentBridge';
import { ClientCache } from '../cache/ClientCache';
import { WorkflowResponse, WorkflowStatusResponse } from '../api/ApiModels';
import { WorkflowViewModel } from '../viewmodels/WorkflowViewModel';
import { ApiDisplayFormatter } from '../utils/ApiDisplayFormatter';

const INTENT_CHIPS: IntentChip[] = [
  { intent: 'get_suggestion', label: '今日建议', prompt: '今天我应该先学什么？' },
  { intent: 'analyze_weakness', label: '薄弱诊断', prompt: '帮我分析最近的学习薄弱点' },
  { intent: 'analyze_wrong', label: '错题分析', prompt: '帮我分析这道错题' },
  { intent: 'match_partner', label: '匹配搭子', prompt: '帮我匹配一个学习搭子' },
  { intent: 'query_tasks', label: '查任务', prompt: '最近有什么任务要交？' },
  { intent: 'update_profile', label: '更新信息', prompt: '帮我更新我的学习信息' },
];

const WELCOME_MESSAGE: ChatMessage = {
  id: 'welcome-1',
  role: 'agent',
  text: '晚上好，我会根据你的课程、DDL、错题和空闲时间，把下一步学习动作说清楚。',
  time: '刚刚',
  status: 'done'
};

@Entry
@Component
struct ChatMain {
  @State messages: ChatMessage[] = [];
  @State inputText: string = '';
  @State pendingImage: string = '';
  @State selectedIntent: string = 'get_suggestion';
  @State isSending: boolean = false;
  @State workflowTitle: string = '';
  @State workflowDetail: string = '';
  @State workflowStateVersion: number = 0;
  @State isWorkflowLoading: boolean = false;
  @State workflowMessage: string = '';
  private messageScroller: Scroller = new Scroller();
  private workflowViewModel: WorkflowViewModel = new WorkflowViewModel();
  private workflowRequestVersion: number = 0;
  private isPageActive: boolean = false;

  aboutToAppear(): void {
    this.isPageActive = true;
    // 恢复之前的对话，没有才显示欢迎消息
    if (appState.hasActiveChat && appState.chatMessages.length > 0) {
      try {
        const saved: ChatMessage[] = JSON.parse(appState.chatMessages) as ChatMessage[];
        this.messages = saved;
      } catch (e) {
        this.messages = [WELCOME_MESSAGE];
      }
    } else {
      this.messages = [WELCOME_MESSAGE];
    }
    // 从其他页面跳回时预填 prompt
    if (appState.pendingChatPrompt.length > 0) {
      this.inputText = appState.pendingChatPrompt;
      appState.pendingChatPrompt = '';
    }
    this.appendTaskHandoff();
    this.scrollToLatestMessage();
    this.refreshWorkflowStatus();
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.workflowRequestVersion++;
    this.isWorkflowLoading = false;
  }

  private scrollToLatestMessage(): void {
    setTimeout(() => {
      this.messageScroller.scrollEdge(Edge.Bottom);
    }, 100);
  }

  private saveMessages(): void {
    appState.chatMessages = JSON.stringify(this.messages);
    appState.hasActiveChat = this.messages.length > 1;
  }

  build() {
    Column() {
      this.Header()
      if (this.workflowTitle.length > 0 || this.workflowMessage.length > 0) {
        this.WorkflowStatusBar()
      }
      this.IntentBar()
      this.MessageList()
      this.InputBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F3F6FA')
  }

  private syncWorkflowSummary(status: WorkflowStatusResponse | null): void {
    const workflow: WorkflowResponse | null = ClientCache.getWorkflow();
    if (workflow === null) {
      this.workflowTitle = '';
      this.workflowDetail = '';
      this.workflowStateVersion = 0;
      return;
    }
    if (status !== null) {
      this.workflowTitle = `${ApiDisplayFormatter.agent(status.currentAgent)} · ${ApiDisplayFormatter.workflowStatus(status.status)}`;
      this.workflowDetail = status.finalAction !== null ? status.finalAction : `正在推进：${workflow.nextAction}`;
      this.workflowStateVersion = status.stateVersion;
      return;
    }
    this.workflowTitle = `Agent 会话 · ${ApiDisplayFormatter.workflowStatus(workflow.status)}`;
    this.workflowDetail = `下一步：${workflow.nextAction}`;
    this.workflowStateVersion = 0;
  }

  private async refreshWorkflowStatus(): Promise<void> {
    const workflow: WorkflowResponse | null = ClientCache.getWorkflow();
    this.syncWorkflowSummary(ClientCache.getWorkflowStatus());
    if (workflow === null || this.isWorkflowLoading) {
      return;
    }
    this.isWorkflowLoading = true;
    this.workflowMessage = '';
    const requestVersion: number = ++this.workflowRequestVersion;
    const status: WorkflowStatusResponse | null = await this.workflowViewModel.refreshStatus(true);
    if (!this.isPageActive || requestVersion !== this.workflowRequestVersion) {
      return;
    }
    this.isWorkflowLoading = false;
    if (status === null) {
      this.workflowMessage = this.workflowViewModel.getErrorMessage();
      return;
    }
    this.syncWorkflowSummary(status);
  }

  @Builder
  private WorkflowStatusBar() {
    Row({ space: 10 }) {
      Column() {
        Text(this.isWorkflowLoading ? '···' : 'AI').fontSize(11).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
      }.width(28).height(28).borderRadius(14).justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center).backgroundColor(this.workflowMessage.length > 0 ? '#B45309' : '#2563EB')
      Column({ space: 2 }) {
        Text(this.workflowTitle.length > 0 ? this.workflowTitle : 'Agent 状态暂时无法同步')
          .fontSize(12).fontWeight(FontWeight.Bold).fontColor('#1F2937')
        Text(this.workflowMessage.length > 0 ? this.workflowMessage : this.workflowDetail)
          .fontSize(11).fontColor('#667085').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (this.workflowMessage.length > 0) {
        Text('重试').fontSize(12).fontWeight(FontWeight.Bold).fontColor('#B45309')
          .onClick(() => this.refreshWorkflowStatus())
      } else {
        Text(this.workflowStateVersion > 0 ? `v${this.workflowStateVersion} ›` : '查看 ›')
          .fontSize(12).fontWeight(FontWeight.Bold).fontColor('#2563EB')
          .onClick(() => router.pushUrl({ url: 'pages/AgentTrace' }))
      }
    }.width('100%').padding({ left: 16, right: 16, top: 9, bottom: 9 })
      .backgroundColor(this.workflowMessage.length > 0 ? '#FFFBEB' : '#EFF6FF')
  }

  @Builder
  private Header() {
    Row() {
      Column({ space: 4 }) {
        Text('知学搭子')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
        Row({ space: 6 }) {
          Text('').width(7).height(7).borderRadius(4).backgroundColor('#3B82F6')
          Text('在线 · AI学习助手')
            .fontSize(12)
            .fontColor('#64748B')
        }
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
      Row({ space: 8 }) {
        Button('工具')
          .fontSize(13)
          .fontColor('#475569')
          .backgroundColor('#F1F5F9')
          .borderRadius(8)
          .height(34)
          .onClick(() => this.openToolbox())
        Button('新对话')
          .fontSize(13)
          .fontColor('#2563EB')
          .backgroundColor('#EAF2FF')
          .borderRadius(8)
          .height(34)
          .onClick(() => this.resetChat())
      }
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 18, bottom: 12 })
    .backgroundColor('#FFFFFF')
    .shadow({ radius: 6, color: '#08000000', offsetX: 0, offsetY: 2 })
  }

  @Builder
  private IntentBar() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(INTENT_CHIPS, (item: IntentChip) => {
          Button(item.label)
            .fontSize(13)
            .fontColor(this.selectedIntent === item.intent ? '#FFFFFF' : '#334155')
            .backgroundColor(this.selectedIntent === item.intent ? '#2563EB' : '#FFFFFF')
            .border({ width: 1, color: this.selectedIntent === item.intent ? '#2563EB' : '#E2E8F0' })
            .borderRadius(8)
            .height(34)
            .padding({ left: 14, right: 14 })
            .onClick(() => {
              this.selectedIntent = item.intent;
              this.inputText = item.prompt;
            })
        }, (item: IntentChip) => item.intent)
      }
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .backgroundColor('#FFFFFF')
  }

  @Builder
  private MessageList() {
    List({ space: 2, scroller: this.messageScroller }) {
      ForEach(this.messages, (item: ChatMessage) => {
        ListItem() {
          this.MessageBubble(item)
        }
      }, (item: ChatMessage) => item.id)
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 8 })
    .backgroundColor('#F3F6FA')
  }

  @Builder
  private MessageBubble(message: ChatMessage) {
    Row() {
      if (message.role === 'user') {
        Blank()
      }

      Column({ space: 8 }) {
        if (message.image !== undefined && message.image.length > 0) {
          Image(message.image)
            .width(112)
            .height(84)
            .objectFit(ImageFit.Cover)
            .borderRadius(8)
            .backgroundColor('#E2E8F0')
        }

        if (message.status === 'sending') {
          Row({ space: 5 }) {
            Text('').width(6).height(6).borderRadius(3).backgroundColor('#8E99A8')
            Text('').width(6).height(6).borderRadius(3).backgroundColor('#B3BBC6')
            Text('').width(6).height(6).borderRadius(3).backgroundColor('#D0D6DE')
          }
          .padding({ left: 14, right: 14, top: 12, bottom: 12 })
          .backgroundColor('#FFFFFF')
          .borderRadius(8)
        } else {
          Text(message.text)
            .fontSize(15)
            .lineHeight(22)
            .fontColor(message.role === 'user' ? '#FFFFFF' : '#1F2933')
            .padding({ left: 14, right: 14, top: 11, bottom: 11 })
            .backgroundColor(message.role === 'user' ? '#2563EB' : '#FFFFFF')
            .borderRadius(8)
        }

        if (message.card !== undefined) {
          this.CardView(message.card)
        }
      }
      .alignItems(message.role === 'user' ? HorizontalAlign.End : HorizontalAlign.Start)
      .width('78%')

      if (message.role !== 'user') {
        Blank()
      }
    }
    .width('100%')
    .justifyContent(message.role === 'user' ? FlexAlign.End : FlexAlign.Start)
    .padding({ left: 16, right: 16, top: 5, bottom: 5 })
  }

  @Builder
  private CardView(card: ChatCard) {
    Column({ space: 6 }) {
      Row() {
        Text(this.getCardLabel(card))
          .fontSize(12)
          .fontColor('#2563EB')
          .fontWeight(FontWeight.Medium)
        Blank()
        Text('查看 ›')
          .fontSize(12)
          .fontColor('#64748B')
      }
      .width('100%')

      Text(card.title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#111827')
        .maxLines(1)
      Text(card.summary)
        .fontSize(13)
        .fontColor('#64748B')
        .lineHeight(18)
        .maxLines(2)

      if (card.actions !== undefined && card.actions.length > 0) {
        Row({ space: 8 }) {
          ForEach(card.actions, (action: ChatAction) => {
            Button(action.label)
              .fontSize(12)
              .fontColor('#2563EB')
              .backgroundColor('#EAF2FF')
              .height(30)
              .borderRadius(8)
              .padding({ left: 10, right: 10 })
              .onClick(() => this.openAction(action))
          }, (action: ChatAction) => action.label + action.targetPage)
        }
        .width('100%')
      }
    }
    .width(226)
    .padding(12)
    .backgroundColor('#F8FAFC')
    .border({ width: 1, color: '#E2E8F0' })
    .borderRadius(8)
    .onClick(() => {
      // 点击卡片本身也跳转
      if (card.actions !== undefined && card.actions.length > 0) {
        this.openAction(card.actions[0]);
      } else if (card.targetPage.length > 0) {
        router.pushUrl({ url: card.targetPage });
      }
    })
  }

  private getCardLabel(card: ChatCard): string {
    if (card.type === 'weakness') {
      return '薄弱诊断';
    }
    if (card.type === 'partner') {
      return '学习搭子';
    }
    if (card.type === 'tasks') {
      return '任务清单';
    }
    if (card.type === 'wrong') {
      return '错题分析';
    }
    return '学习建议';
  }

  private openAction(action: ChatAction): void {
    appState.startChatTask(this.taskContextFor(action.targetPage));
    router.pushUrl({ url: action.targetPage });
  }

  private openToolbox(): void {
    appState.startChatTask('浏览全部学习工具');
    router.pushUrl({ url: 'pages/Index' });
  }

  private taskContextFor(targetPage: string): string {
    if (targetPage === 'pages/WrongQuestion') {
      return '诊断并安排错题复习';
    }
    if (targetPage === 'pages/PartnerMatch') {
      return '选择合适的学习搭子';
    }
    if (targetPage === 'pages/StudyPlan') {
      return '确认本周复习计划';
    }
    if (targetPage === 'pages/FocusSetup') {
      return '开始本次专注';
    }
    return '确认今天的学习任务';
  }

  private appendTaskHandoff(): void {
    const handoff: ChatHandoff | null = appState.consumeChatHandoff();
    if (handoff === null) {
      return;
    }
    const action: ChatAction = {
      label: handoff.actionLabel,
      targetPage: handoff.targetPage
    };
    const data: Map<string, string> = new Map<string, string>();
    data.set('source', 'task_handoff');
    const card: ChatCard = {
      type: 'suggestion',
      title: handoff.nextPrompt,
      summary: '继续完成下一步，或直接在对话里调整安排。',
      targetPage: handoff.targetPage,
      data: data,
      actions: [action]
    };
    const message: ChatMessage = {
      id: `handoff-${Date.now()}`,
      role: 'agent',
      text: handoff.summary,
      card: card,
      time: this.formatTime(),
      status: 'done'
    };
    this.messages = this.messages.concat([message]);
    this.saveMessages();
    this.scrollToLatestMessage();
  }

  @Builder
  private InputBar() {
    Column({ space: 8 }) {
      if (this.pendingImage.length > 0) {
        Row({ space: 10 }) {
          Image(this.pendingImage)
            .width(54)
            .height(54)
            .objectFit(ImageFit.Cover)
            .borderRadius(8)
            .backgroundColor('#E2E8F0')
          Text('已添加图片')
            .fontSize(13)
            .fontColor('#475569')
          Blank()
          Button('移除')
            .fontSize(12)
            .fontColor('#64748B')
            .backgroundColor('#F1F5F9')
            .height(30)
            .borderRadius(8)
            .onClick(() => this.pendingImage = '')
        }
        .width('100%')
      }

      Row({ space: 8 }) {
        Button('🎤×')
          .fontSize(16)
          .backgroundColor('#E5E7EB')
          .width(40)
          .height(40)
          .borderRadius(8)
          .enabled(false)
        Button('📷')
          .fontSize(16)
          .backgroundColor('#EAF2FF')
          .width(40)
          .height(40)
          .borderRadius(8)
          .onClick(() => this.pickImage())
        TextInput({ placeholder: '问学习建议、错题、计划或搭子', text: this.inputText })
          .height(40)
          .layoutWeight(1)
          .fontSize(14)
          .placeholderColor('#94A3B8')
          .fontColor('#111827')
          .backgroundColor('#F8FAFC')
          .borderRadius(8)
          .onChange((value: string) => this.inputText = value)
        Button('发送')
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor(this.canSend() ? '#2563EB' : '#CBD5E1')
          .height(40)
          .borderRadius(8)
          .enabled(this.canSend())
          .onClick(() => this.sendMessage())
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 14 })
    .backgroundColor('#FFFFFF')
  }

  private canSend(): boolean {
    return !this.isSending && (this.inputText.trim().length > 0 || this.pendingImage.length > 0);
  }

  private resetChat(): void {
    this.messages = [WELCOME_MESSAGE];
    this.inputText = '';
    this.pendingImage = '';
    this.selectedIntent = 'get_suggestion';
    this.isSending = false;
    appState.hasActiveChat = false;
    appState.chatMessages = '';
  }

  private startVoiceInput(): void {
    // 语音输入提示（真机可用 @ohos.ai.speechRecognizer）
    const fallbackMsg: ChatMessage = {
      id: `voice-fallback-${Date.now()}`,
      role: 'agent',
      text: '语音输入需要真机支持。你可以直接打字，或者拍照上传错题～',
      time: this.formatTime(),
      status: 'done'
    };
    this.messages = [...this.messages, fallbackMsg];
  }

  private async pickImage(): Promise<void> {
    try {
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      const result = await photoPicker.select(options);
      if (result.photoUris.length > 0) {
        const uri: string = result.photoUris[0];
        this.pendingImage = uri;
        appState.addWrongQuestionImage(uri, `chat_${Date.now()}.jpg`);
      }
    } catch (error) {
      const imageErrorMessage: ChatMessage = {
        id: `image-error-${Date.now()}`,
        role: 'agent',
        text: '图片选择暂时没有成功，你可以先发文字，我会保留图片入口等后续联调。',
        time: this.formatTime(),
        status: 'done'
      };
      this.messages = [...this.messages, imageErrorMessage];
    }
  }

  private async sendMessage(): Promise<void> {
    if (!this.canSend()) {
      return;
    }

    const text: string = this.inputText.trim().length > 0 ? this.inputText.trim() : '请分析这张图片';
    const image: string | undefined = this.pendingImage.length > 0 ? this.pendingImage : undefined;
    const userMessage: ChatMessage = {
      id: `user-${Date.now()}`,
      role: 'user',
      text: text,
      image: image,
      time: this.formatTime(),
      status: 'done'
    };
    const loadingMessage: ChatMessage = {
      id: `agent-loading-${Date.now()}`,
      role: 'agent',
      text: '',
      time: this.formatTime(),
      status: 'sending'
    };

    this.messages = [...this.messages, userMessage, loadingMessage];
    this.inputText = '';
    this.pendingImage = '';
    this.isSending = true;
    this.scrollToLatestMessage();

    try {
      const response = await AgentBridge.callAgent(text, image, this.messages);
      this.messages = this.messages.filter((item: ChatMessage) => item.id !== loadingMessage.id);
      const agentMessage: ChatMessage = {
        id: `agent-${Date.now()}`,
        role: 'agent',
        text: response.reply,
        card: response.card,
        time: this.formatTime(),
        status: 'done'
      };
      this.messages = [...this.messages, agentMessage];
      this.saveMessages();
      this.scrollToLatestMessage();
    } catch (error) {
      this.messages = this.messages.filter((item: ChatMessage) => item.id !== loadingMessage.id);
      const errorMessage: ChatMessage = {
        id: `agent-error-${Date.now()}`,
        role: 'agent',
        text: error instanceof Error ? error.message : '这次没有连上 Agent，请检查数据源后重试。',
        time: this.formatTime(),
        status: 'error'
      };
      this.messages = [...this.messages, errorMessage];
      this.inputText = text;
      this.pendingImage = image ?? '';
      this.saveMessages();
      this.scrollToLatestMessage();
    }
    this.isSending = false;
  }

  private formatTime(): string {
    const now = new Date();
    const hour: number = now.getHours();
    const minute: number = now.getMinutes();
    const minuteText: string = minute < 10 ? `0${minute}` : `${minute}`;
    return `${hour}:${minuteText}`;
  }
}
