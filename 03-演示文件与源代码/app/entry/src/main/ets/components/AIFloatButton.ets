import { ChatMessage } from '../models/ChatModels';
import { AgentBridge } from '../services/AgentBridge';

/**
 * AIFloatButton - 全局可拖拽 AI 浮标 + 弹出式对话小窗
 *
 * 特性：
 * - 浮标可拖拽移动（PanGesture）
 * - 点击浮标弹出/收起 AI 对话窗口
 * - 窗口内可直接与后端 LLM 对话
 * - 浮标和窗口不阻挡下层页面触摸事件
 *
 * 用法：在页面 build() 最外层用 Stack 包裹，将浮标放在内容后面即可
 */
@Component
export struct AIFloatButton {
  @State showPanel: boolean = false;
  @State translateX: number = 0;
  @State translateY: number = 0;
  @State messages: ChatMessage[] = [];
  @State inputText: string = '';
  @State isSending: boolean = false;
  private scroller: Scroller = new Scroller();
  private msgIdCounter: number = 0;
  // 拖拽起始位置（手势开始时记录，避免累积偏移飞出去）
  private dragStartX: number = 0;
  private dragStartY: number = 0;

  aboutToAppear(): void {
    this.messages = [{
      id: 'float-welcome',
      role: 'agent',
      // 这里列的六项与 `ChatMain.INTENT_CHIPS` 一一对应，且用**页面标题**口径，
      // 保证"浮标里看到的"与"对话页按钮上写的"是同一套名字。
      text: '你好！我是知学 Mate 助手。\n\n可以问我：\n• 今日学习建议\n• 学情画像\n• 错题诊断\n• 学习搭子\n• 今日任务\n• 学习画像更新',
      time: '',
      status: 'done'
    }];
  }

  private makeId(): string {
    this.msgIdCounter++;
    return `float-${this.msgIdCounter}`;
  }

  private getTimeLabel(): string {
    const d: Date = new Date();
    const h: string = d.getHours().toString().padStart(2, '0');
    const m: string = d.getMinutes().toString().padStart(2, '0');
    return `${h}:${m}`;
  }

  private async sendMessage(): Promise<void> {
    const text: string = this.inputText.trim();
    if (text === '' || this.isSending) {
      return;
    }

    const userMessage: ChatMessage = {
      id: this.makeId(),
      role: 'user',
      text: text,
      time: this.getTimeLabel(),
      status: 'done'
    };
    this.inputText = '';
    this.isSending = true;

    const loadingMessage: ChatMessage = {
      id: this.makeId(),
      role: 'agent',
      text: '思考中...',
      time: this.getTimeLabel(),
      status: 'sending'
    };
    // 原缺陷：与 ChatMain.sendMessage 同一形态——递给 callAgent 的数组里已经含本条
    // userMessage（buildRequest 只过滤 status === 'sending'，拦不住 done 的用户消息），
    // 同一条输入会同时出现在请求体的 `message` 与 `history` 末项里。
    // 这里先取"发送前"的历史快照，本条消息由 `message` 字段承载。
    const historyBeforeSend: ChatMessage[] = this.messages;
    this.messages = [...this.messages, userMessage, loadingMessage];
    this.scrollToBottom();

    try {
      const response = await AgentBridge.callAgent(text, undefined, historyBeforeSend);
      // 移除 loading 消息，加入真实回复
      this.messages = this.messages.filter((item: ChatMessage) => item.id !== loadingMessage.id);
      const agentMessage: ChatMessage = {
        id: this.makeId(),
        role: 'agent',
        text: response.reply,
        time: this.getTimeLabel(),
        status: 'done',
        card: response.card
      };
      this.messages = [...this.messages, agentMessage];
    } catch (e) {
      this.messages = this.messages.filter((item: ChatMessage) => item.id !== loadingMessage.id);
      const errorMessage: ChatMessage = {
        id: this.makeId(),
        role: 'agent',
        text: '⚠️ 连接失败，请确认后端已启动（python app.py），或稍后重试。',
        time: this.getTimeLabel(),
        status: 'error'
      };
      this.messages = [...this.messages, errorMessage];
    }

    this.isSending = false;
    this.scrollToBottom();
  }

  private scrollToBottom(): void {
    this.scroller.scrollEdge(Edge.Bottom);
  }

  build() {
    Column() {
      // ==========================================
      // 弹出式 AI 对话窗口（浮标上方）
      // ==========================================
      if (this.showPanel) {
        Column() {
          // ---- 标题栏 ----
          Row() {
            Row({ space: 6 }) {
              Text('').width(8).height(8).borderRadius(4).backgroundColor('#22C55E')
              Text('AI 助手')
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
            }
            Blank()
            Text('✕')
              .fontSize(18)
              .fontColor('#FFFFFF')
              .padding({ left: 8, right: 4, top: 2, bottom: 2 })
              .onClick(() => {
                this.showPanel = false;
              })
          }
          .width('100%')
          .padding({ left: 14, right: 10, top: 12, bottom: 12 })
          .backgroundColor('#2563EB')
          .borderRadius({ topLeft: 16, topRight: 16 })

          // ---- 消息列表 ----
          Scroll(this.scroller) {
            Column({ space: 10 }) {
              ForEach(this.messages, (msg: ChatMessage, index: number) => {
                if (msg.role === 'user') {
                  // 用户消息（右对齐，蓝色气泡）
                  Row() {
                    Blank()
                    Text(msg.text)
                      .fontSize(13)
                      .fontColor('#FFFFFF')
                      .backgroundColor('#2563EB')
                      .borderRadius({ topLeft: 12, topRight: 12, bottomLeft: 12, bottomRight: 4 })
                      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                      .constraintSize({ maxWidth: '75%' })
                  }
                  .width('100%')
                  .padding({ left: 40, right: 4 })
                } else {
                  // Agent 消息（左对齐，灰色气泡）
                  Column({ space: 4 }) {
                    Row() {
                      Text(msg.text)
                        .fontSize(13)
                        .fontColor('#334155')
                        .backgroundColor('#F1F5F9')
                        .borderRadius({ topLeft: 12, topRight: 12, bottomLeft: 4, bottomRight: 12 })
                        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                        .constraintSize({ maxWidth: '80%' })
                      Blank()
                    }
                    .width('100%')
                    .padding({ left: 4, right: 40 })
                  }
                  .width('100%')
                }
              // 原缺陷：key 生成器是 `${msg.id}-${index}`，而上面（成功 / 失败分支）
              // 会从中间删掉 loading 消息，其后所有元素的 index 都往前挪一位，
              // ArkUI 据此判定"换了一批元素"→ 整列气泡销毁重建：
              // 表现为闪烁，滚动位置与子组件状态全部丢失。
              // `makeId()` 已保证 msg.id 全局唯一且稳定，key 只用它即可。
              }, (msg: ChatMessage) => msg.id)
            }
            .width('100%')
            .padding(12)
          }
          .layoutWeight(1)
          .backgroundColor('#F8FAFC')
          .height(200)

          // ---- 输入区域 ----
          Row({ space: 8 }) {
            TextInput({ placeholder: '输入问题...', text: this.inputText })
              .layoutWeight(1)
              .height(38)
              .fontSize(13)
              .backgroundColor('#F1F5F9')
              .borderRadius(19)
              .padding({ left: 14, right: 14 })
              .onChange((value: string) => {
                this.inputText = value;
              })
              .onSubmit(() => {
                this.sendMessage();
              })
            Button('发送')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .backgroundColor('#2563EB')
              .height(34)
              .borderRadius(17)
              .padding({ left: 14, right: 14 })
              .enabled(!this.isSending)
              .onClick(() => {
                this.sendMessage();
              })
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 8, bottom: 10 })
          .backgroundColor('#FFFFFF')
          .borderRadius({ bottomLeft: 16, bottomRight: 16 })
        }
        .width('92%')
        .height(380)
        .borderRadius(16)
        .backgroundColor('#FFFFFF')
        .shadow({ radius: 24, color: '#30000000', offsetX: 0, offsetY: 8 })
        .margin({ bottom: 12 })
      }

      // ==========================================
      // 空白弹性空间 → 把浮标推到底部
      // ==========================================
      Blank()

      // ==========================================
      // 可拖拽 AI 浮标按钮
      // ==========================================
      Row() {
        Blank()
        Button() {
          Row({ space: 5 }) {
            Text('💬')
              .fontSize(20)
            Text('AI')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
          }
          .padding({ left: 12, right: 14, top: 9, bottom: 9 })
        }
        .backgroundColor('#2563EB')
        .borderRadius(26)
        .shadow({ radius: 14, color: '#402563EB', offsetX: 0, offsetY: 5 })
        .translate({ x: this.translateX, y: this.translateY })
        .gesture(
          PanGesture({ fingers: 1, direction: PanDirection.All, distance: 3 })
            .onActionStart((event: GestureEvent) => {
              // 记录拖拽开始时的当前位置
              this.dragStartX = this.translateX;
              this.dragStartY = this.translateY;
            })
            .onActionUpdate((event: GestureEvent) => {
              // offset 是累积偏移，直接加到起始位置，不累加
              this.translateX = this.dragStartX + event.offsetX;
              this.translateY = this.dragStartY + event.offsetY;
            })
        )
        .onClick(() => {
          this.showPanel = !this.showPanel;
        })
      }
      .width('100%')
      .padding({ right: 20, bottom: 24 })
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
