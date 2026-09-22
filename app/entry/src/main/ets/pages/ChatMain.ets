import router from '@ohos.router';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { appState } from '../data/AppState';
import { ChatAction, ChatCard, ChatHandoff, ChatMessage, IntentChip } from '../models/ChatModels';
import { AgentBridge } from '../services/AgentBridge';
import { ClientCache } from '../cache/ClientCache';
import { WorkflowResponse, WorkflowStatusResponse } from '../api/ApiModels';
import { WorkflowViewModel } from '../viewmodels/WorkflowViewModel';
import { ApiDisplayFormatter } from '../utils/ApiDisplayFormatter';
import { VoiceInputCallbacks, VoiceInputService } from '../services/VoiceInputService';

/**
 * 对话页顶部的六个意图快捷按钮。
 *
 * ⚠️ 三条纪律（改动前务必读完）：
 *
 * 1. **`intent` 不能改** —— 这六个值是前后端契约（`api-contract-v0.3`）里
 *    意图识别的枚举，后端 `chat_llm.INTENT_CARDS` 与 `KNOWN_INTENTS`
 *    都按这六个键取值。改 key 会直接打断意图路由。
 *
 * 2. **`label` 必须等于用户点下去之后真正会看到的页面/卡片名字**。
 *    原来写的是"今日建议 / 薄弱诊断 / 查任务 / 更新信息"这类**内部叫法**，
 *    而落地页标题是"今日学习建议 / 学情画像 / Agent 学习计划"——
 *    按钮说什么、点进去看到什么，两边对不上，用户会怀疑点错了。
 *    现在一律以页面标题为准。
 *
 * 3. **一个按钮只能落到一个页面**。原实现在离线 Fixture 下把
 *    `get_suggestion` 与 `query_tasks` 合并成同一张"学习计划"卡，
 *    导致两个不同按钮点出同一个结果（见 `AgentBridge.createLocalCardForIntent`）。
 */
const INTENT_CHIPS: IntentChip[] = [
  { intent: 'get_suggestion', label: '今日学习建议', prompt: '今天我应该先学什么？' },
  { intent: 'analyze_wrong', label: '错题诊断', prompt: '帮我诊断这道错题' },
  { intent: 'analyze_weakness', label: '学情画像', prompt: '帮我看看我的薄弱知识点' },
  { intent: 'match_partner', label: '学习搭子', prompt: '帮我匹配一个学习搭子' },
  { intent: 'query_tasks', label: '今日任务', prompt: '今天有哪些任务要交？' },
  { intent: 'update_profile', label: '学习画像', prompt: '我掌握了二叉树遍历，帮我更新画像' },
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
  /** 当前标签：对话页自身固定为 0，仅用于驱动底部标签栏高亮。 */
  @State activeTab: number = 0;
  @State isSending: boolean = false;
  @State workflowTitle: string = '';
  @State workflowDetail: string = '';
  @State workflowStateVersion: number = 0;
  @State isWorkflowLoading: boolean = false;
  @State workflowMessage: string = '';
  @State isListening: boolean = false;
  @State voiceMessage: string = '';
  private messageScroller: Scroller = new Scroller();
  private workflowViewModel: WorkflowViewModel = new WorkflowViewModel();
  private workflowRequestVersion: number = 0;
  private isPageActive: boolean = false;
  private voiceInputService: VoiceInputService = new VoiceInputService();

  aboutToAppear(): void {
    this.isPageActive = true;
    // 恢复之前的对话；**没有历史时保持为空**，由 WelcomeBlock 呈现"纯对话界面"。
    //
    // ⚠️ 修正来源：原实现在无历史时种入一条 WELCOME_MESSAGE 气泡，
    // 结果 `messages.length === 0` 永远不成立，欢迎引导（问候语 + 输入框）
    // 从来没显示过，首屏看起来就是"一条机器人寒暄"，不是想要的对话界面。
    if (appState.hasActiveChat && appState.chatMessages.length > 0) {
      try {
        const saved: ChatMessage[] = JSON.parse(appState.chatMessages) as ChatMessage[];
        this.messages = saved;
      } catch (e) {
        this.messages = [];
      }
    } else {
      this.messages = [];
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
    this.isListening = false;
    void this.voiceInputService.dispose();
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
      this.TabBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F3F6FA')
  }

  /**
   * 底部标签栏（与「我的智能体」页保持一致的四标签语义）。
   *
   * ⚠️ 必须无参，高亮在内部读 `this.activeTab`——原因见 Index.ets 的同名注释：
   * ArkTS 的 `@Builder` 参数按值传递，把状态当参数传会导致高亮不刷新。
   */
  @Builder
  private TabBar() {
    Row({ space: 4 }) {
      this.TabItem('◈', '对话', 0)
      this.TabItem('▦', '智能体', 1)
      this.TabItem('▤', '学习', 2)
      this.TabItem('◉', '我的', 3)
    }
    .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 10 })
    .backgroundColor('#FFFFFF').border({ width: { top: 1 }, color: '#EAECF0' })
  }

  @Builder
  private TabItem(icon: string, label: string, index: number) {
    Column({ space: 3 }) {
      Text(icon).fontSize(19)
        .fontColor(this.activeTab === index ? '#2563EB' : '#667085')
      Text(label).fontSize(11)
        .fontWeight(this.activeTab === index ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.activeTab === index ? '#2563EB' : '#667085')
    }
    .layoutWeight(1).height(58).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .backgroundColor(this.activeTab === index ? '#EFF6FF' : '#FFFFFF').borderRadius(12)
    .onClick(() => this.switchTab(index))
  }

  /**
   * 标签切换。对话页自身是 0 号标签，其余三个跳转到工作台页。
   *
   * 用 `replaceUrl` 而不是 `pushUrl`：标签是**同级导航**，
   * 若用 pushUrl 会让页面栈随每次切换不断增长（用户在标签间来回点几次就退不出去了）。
   *
   * 「智能体」与「学习」都在 `pages/Index` 里（同一页的不同标签），
   * 用路由参数 `initialTab` 指定落地标签；`Index.aboutToAppear` 会读取它。
   */
  private switchTab(index: number): void {
    if (index === 0) {
      return;
    }
    if (index === 1) {
      router.replaceUrl({ url: 'pages/Index', params: { initialTab: 1 } });
      return;
    }
    if (index === 2) {
      router.replaceUrl({ url: 'pages/Index', params: { initialTab: 2 } });
      return;
    }
    router.replaceUrl({ url: 'pages/Index', params: { initialTab: 3 } });
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
        Text('知学 Mate')
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
      // 消息为空时展示欢迎引导：对齐参考设计「问候语 + 一句话价值 + 输入框」的首屏。
      // 用 ListItem 承载是为了能跟着列表一起滚动，不与既有 List 结构冲突。
      if (this.messages.length === 0) {
        ListItem() {
          this.WelcomeBlock()
        }
      }
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

  /** 按当前时间给出问候语（早上好 / 下午好 / 晚上好）。 */
  private greetingText(): string {
    const hour: number = new Date().getHours();
    if (hour < 6) return '夜深了';
    if (hour < 12) return '早上好';
    if (hour < 18) return '下午好';
    return '晚上好';
  }

  /**
   * 首次进入的欢迎区。
   *
   * 参考设计的首屏是「大号问候 + 一句话说明产品做什么 + 输入框」，
   * 这套结构比一上来就弹一排功能按钮更清楚：先让人知道**能对它说什么**。
   */
  @Builder
  private WelcomeBlock() {
    Column({ space: 10 }) {
      Text('ZHI XUE MATE  ·  LEARNING AGENT')
        .fontSize(10).fontWeight(FontWeight.Bold).fontColor('#94A3B8')
        .letterSpacing(1.5).width('100%')
      Text(`${this.greetingText()}，`)
        .fontSize(26).fontWeight(FontWeight.Bold).fontColor('#0F172A').width('100%')
      Text('从今天最该做的一件事开始。')
        .fontSize(26).fontWeight(FontWeight.Bold).fontColor('#0F172A').width('100%')
      Divider().color('#CBD5E1').width(160).margin({ top: 6, bottom: 2 })
      Text('我已经读取你的课程、考试倒计时与错题记录。你可以直接说想做什么，')
        .fontSize(13).fontColor('#64748B').lineHeight(20).width('100%')
      Text('也可以点下面的能力，或去「智能体」页看看我全部会做的事。')
        .fontSize(13).fontColor('#64748B').lineHeight(20).width('100%')
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, top: 28, bottom: 18 })
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

        if (message.role === 'agent' && message.status === 'done' && message.llmUsed !== undefined) {
          Text(message.llmUsed ? '大模型生成' : '本地规则兜底')
            .fontSize(11)
            .fontColor(message.llmUsed ? '#2563EB' : '#B45309')
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor(message.llmUsed ? '#EAF2FF' : '#FFF7ED')
            .borderRadius(10)
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

  /**
   * 卡片类型 → 卡片上的名称标签。
   *
   * ⚠️ 这里的文案必须与下面 `INTENT_CHIPS` 的 `label` **同一套口径**，
   * 否则会出现"按钮写学情画像、点进去卡片写薄弱诊断"的错位。
   * 统一规则：一律用页面标题（今日学习建议 / 学情画像 / 学习搭子 / 今日任务 / 错题诊断）。
   */
  private getCardLabel(card: ChatCard): string {
    if (card.type === 'weakness') {
      return '学情画像';
    }
    if (card.type === 'partner') {
      return '学习搭子';
    }
    if (card.type === 'tasks') {
      return '今日任务';
    }
    if (card.type === 'wrong') {
      return '错题诊断';
    }
    return '今日学习建议';
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
      if (this.voiceMessage.length > 0) {
        Row({ space: 8 }) {
          Text(this.isListening ? '●' : 'i')
            .fontSize(11).fontColor(this.isListening ? '#DC2626' : '#2563EB')
          Text(this.voiceMessage).fontSize(12).fontColor('#475569').layoutWeight(1)
          if (this.isListening) {
            Text('完成').fontSize(12).fontWeight(FontWeight.Bold).fontColor('#DC2626')
              .onClick(() => { void this.stopVoiceInput(); })
          }
        }.width('100%').padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .backgroundColor(this.isListening ? '#FEF2F2' : '#EFF6FF').borderRadius(8)
      }
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
        // 语音输入按钮。
        // ⚠️ 图标必须用系统 Symbol 字体（`sys.symbol.*`），不要用 emoji：
        //   原先写的是 `Button(this.isListening ? '■' : '🎤')`，
        //   emoji 字形取决于系统 emoji 字体，在不同设备/版本上大小、基线、
        //   配色都不一致，且在部分精简镜像里根本不渲染。
        //   Symbol 由 HM Symbol 字体提供，可随 fontSize / fontColor 精确控制。
        //   符号名取自本机 SDK 资源表
        //   `sdk/default/openharmony/toolchains/id_defined.json`（type == "symbol"），
        //   已核实 `mic` / `stop_circle_fill` / `camera` 均存在。
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          SymbolGlyph(this.isListening
            ? $r('sys.symbol.stop_circle_fill')
            : $r('sys.symbol.mic'))
            .fontSize(20)
            .fontColor([this.isListening ? '#FFFFFF' : '#2563EB'])
        }
        .backgroundColor(this.isListening ? '#DC2626' : '#EAF2FF')
        .width(40)
        .height(40)
        .borderRadius(8)
        .enabled(!this.isSending)
        .onClick(() => { void this.toggleVoiceInput(); })
        // 拍照上传按钮。语义是"拍照识别错题"，因此用相机图标而非相册/图片图标。
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.camera'))
            .fontSize(20)
            .fontColor(['#2563EB'])
        }
        .backgroundColor('#EAF2FF')
        .width(40)
        .height(40)
        .borderRadius(8)
        .enabled(!this.isSending)
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

  private async toggleVoiceInput(): Promise<void> {
    if (this.isListening) {
      await this.stopVoiceInput();
      return;
    }
    await this.startVoiceInput();
  }

  private async startVoiceInput(): Promise<void> {
    this.voiceMessage = '';
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const permissions: Permissions[] = ['ohos.permission.MICROPHONE'];
    try {
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, permissions);
      if (result.authResults.length === 0 || result.authResults[0] !== 0) {
        this.voiceMessage = '麦克风权限未开启，可在系统设置中允许后重试。';
        return;
      }
    } catch (error) {
      this.voiceMessage = '无法申请麦克风权限，请在系统设置中检查权限。';
      return;
    }

    const callbacks: VoiceInputCallbacks = new VoiceInputCallbacks(
      (listening: boolean): void => {
        this.isListening = listening;
        if (listening) this.voiceMessage = '正在聆听，点击红色停止按钮后生成文字。';
      },
      (text: string, isFinal: boolean): void => {
        this.inputText = text;
        this.voiceMessage = isFinal ? '已转换为文字，可修改后发送。' : '正在识别…';
      },
      (message: string): void => {
        this.isListening = false;
        this.voiceMessage = message;
      }
    );
    await this.voiceInputService.start(callbacks);
  }

  private async stopVoiceInput(): Promise<void> {
    this.voiceMessage = '正在整理识别结果…';
    await this.voiceInputService.stop(true);
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
        llmUsed: response.llmUsed,
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
