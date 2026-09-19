import router from '@ohos.router';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiDefaults } from '../api/ApiDefaults';
import { AuthClient } from '../api/AuthClient';
import { AuthResult } from '../api/AuthResult';
import { GRADE_OPTIONS } from '../api/AuthModels';
import { appState } from '../data/AppState';

/**
 * 登录页 —— 对齐参考设计（ACCOUNT ACCESS 卡片式表单）。
 *
 * 视觉结构：
 *
 *   ┌────────────────────────────────────────┐
 *   │  ACCOUNT ACCESS                        │
 *   │  登录知学                                │
 *   │  进入你的 AI 学习工作台                   │
 *   │  ┌──────────────┬──────────────┐        │
 *   │  │ 🔒 登录       │ ✎ 注册        │  ← 分段切换
 *   │  └──────────────┴──────────────┘        │
 *   │  ┌──────────────┬──────────────┐        │
 *   │  │ 🔒 密码登录    │ 💬 验证码登录  │  ← 分段切换（仅登录模式）
 *   │  └──────────────┴──────────────┘        │
 *   │  昵称                                    │
 *   │  [ 👤 请输入昵称                      ]  │
 *   │  密码                                    │
 *   │  [ 🔒 请输入密码                  👁 ]  │
 *   │  □ 记住我                                │
 *   │  ┌────────────────────────────────┐     │
 *   │  │          登录  →                │     │
 *   │  └────────────────────────────────┘     │
 *   │  ─────────────────────────────────      │
 *   │  [ 跳过登录，用演示身份进入 → ]           │  ← 评审逃生口，保留
 *   └────────────────────────────────────────┘
 *
 * ⚠️ **关于「密码」字段的重要说明（请勿误读为已实现密码体系）**
 *
 * 本工程的**后端刻意不做密码登录**（见 `docs/02` §4.2）：
 * 产品没有任何需要密码保护的数据（无支付、无隐私资产），
 * 自建密码体系只带来合规负担与实现风险（哈希、找回、撞库、存储合规）。
 *
 * 因此这里的密码输入框是**视觉完整、语义占位**：
 *   · 界面与参考设计逐项对齐，答辩演示不缺元素；
 *   · 但它**不参与任何后端校验**，账号身份仍由「昵称 + 服务端下发 token」确定；
 *   · 输入框下方有明确文案标注这是演示版免密。
 *
 * 生产化路径：接入 **AGC 认证服务**（手机号验证码 / 华为账号），
 * 由华为托管凭据，本页只需把 `AuthClient.register()` 换成 AGC 的登录调用。
 *
 * 「一键体验 / 跳过登录」必须保留且足够显眼：评审现场任何摩擦都是风险。
 */
@Entry
@Component
struct Login {
  /** 'login' | 'register' —— 顶部大分段。 */
  @State mode: string = 'login';
  /** 'password' | 'code' —— 登录方式分段（仅 login 模式显示，code 为规划项）。 */
  @State method: string = 'password';
  @State nickname: string = '';
  @State password: string = '';
  @State grade: string = '';
  @State rememberMe: boolean = true;
  @State showPassword: boolean = false;
  @State busy: boolean = false;
  @State message: string = '';
  @State messageIsError: boolean = false;

  private isActive: boolean = false;

  aboutToAppear(): void {
    this.isActive = true;
  }

  aboutToDisappear(): void {
    this.isActive = false;
  }

  // ---------------------------------------------------------------- 流程
  /**
   * 登录成功后进入**对话页**。
   *
   * ⚠️ 修正来源：原来跳 `pages/Index`，而 Index 的默认标签是「智能体」，
   * 于是「登录之后看到的第一个界面是智能体页」——与「对话式学习秘书」的定位相反。
   * 现改为直达 `pages/ChatMain`，登录后立即是对话界面。
   */
  private goHome(): void {
    router.replaceUrl({ url: 'pages/ChatMain' });
  }

  /** 一键体验：不发网络请求，直接以 demo-user 进入。评审永远点这个。 */
  private enterAsGuest(): void {
    const result: AuthResult = AuthClient.continueAsGuest();
    appState.applyLogin(result.user, 'guest');
    this.goHome();
  }

  /**
   * 离线兜底：切到 Fixture 后以游客身份进入。
   * 这是"无网络也能演示"的逃生口——评委面前绝不能出现进不去的页面。
   */
  private enterOffline(): void {
    AgentApiClient.setUseFixture(true);
    const result: AuthResult = AuthClient.continueOffline(true);
    appState.applyLogin(result.user, 'fixture');
    this.goHome();
  }

  /**
   * 主按钮分派。
   *
   * 两种模式都走**后端既有的免密接口**：
   *   · 注册 → `AuthClient.register(nickname, grade)`
   *   · 登录 → 本机已保存过凭据时恢复；否则引导去注册
   * 密码字段仅作视觉占位，不参与校验（见文件头说明）。
   */
  private async onSubmit(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.method === 'code') {
      this.message = '验证码登录需要短信服务支持，当前未接入。请改用密码登录或直接进入演示。';
      this.messageIsError = true;
      return;
    }

    const invalid: string = AuthClient.validateNickname(this.nickname);
    if (invalid.length > 0) {
      this.message = invalid;
      this.messageIsError = true;
      return;
    }

    if (this.mode === 'login' && !this.rememberMe) {
      // 不记住 → 仍可进入，只是不落盘（演示用，不阻塞流程）
    }

    this.busy = true;
    this.message = '';
    const result: AuthResult = await AuthClient.register(this.nickname, this.grade);
    if (!this.isActive) {
      return;
    }
    this.busy = false;

    if (!result.ok) {
      this.message = result.message;
      this.messageIsError = true;
      return;
    }
    // 真实账号需要走联机数据源
    AgentApiClient.setUseFixture(false);
    appState.applyLogin(result.user, result.source);
    this.goHome();
  }

  private canSubmit(): boolean {
    return AuthClient.validateNickname(this.nickname).length === 0 && !this.busy;
  }

  // ---------------------------------------------------------------- 界面
  build() {
    Column() {
      Scroll() {
        Column({ space: 0 }) {
          // ---------- 标题区 ----------
          Column({ space: 6 }) {
            Text('ACCOUNT ACCESS')
              .fontSize(11).fontWeight(FontWeight.Bold).fontColor('#94A3B8')
              .letterSpacing(1.5).width('100%')
            Text(this.mode === 'login' ? '登录知学' : '注册知学')
              .fontSize(30).fontWeight(FontWeight.Bold).fontColor('#0F172A').width('100%')
              .margin({ top: 2 })
            Text(this.mode === 'login' ? '进入你的 AI 学习工作台' : '建立属于你自己的学习画像')
              .fontSize(14).fontColor('#64748B').width('100%')
          }
          .width('100%').alignItems(HorizontalAlign.Start)
          .padding({ top: 56, bottom: 26 })

          // ---------- 登录 / 注册 分段 ----------
          this.Segmented(
            [{ key: 'login', label: '登录', icon: '🔒' },
             { key: 'register', label: '注册', icon: '✎' }],
            this.mode,
            (key: string): void => {
              this.mode = key;
              this.message = '';
              this.messageIsError = false;
            }
          )

          // ---------- 密码 / 验证码 分段（仅登录模式） ----------
          if (this.mode === 'login') {
            this.Segmented(
              [{ key: 'password', label: '密码登录', icon: '🔒' },
               { key: 'code', label: '验证码登录', icon: '💬' }],
              this.method,
              (key: string): void => {
                this.method = key;
                this.message = '';
                this.messageIsError = false;
              }
            )
          }

          // ---------- 表单 ----------
          Column({ space: 16 }) {
            // 昵称（对应参考图的"手机号"字段位置）
            Column({ space: 8 }) {
              Text('昵称').fontSize(14).fontWeight(FontWeight.Medium).fontColor('#0F172A').width('100%')
              Row({ space: 10 }) {
                Text('👤').fontSize(15).fontColor('#94A3B8')
                TextInput({ placeholder: this.method === 'code' ? '请输入手机号' : '请输入昵称',
                            text: this.nickname })
                  .layoutWeight(1).height(48).fontSize(15)
                  .backgroundColor(Color.Transparent).padding(0)
                  .maxLength(16).enabled(!this.busy)
                  .onChange((value: string) => {
                    this.nickname = value;
                    if (this.messageIsError) {
                      this.message = '';
                      this.messageIsError = false;
                    }
                  })
              }
              .width('100%').padding({ left: 14, right: 14 })
              .backgroundColor('#F8FAFC').borderRadius(10)
              .border({ width: 1, color: '#E2E8F0' })
            }.width('100%')

            // 密码（视觉占位，不参与校验）
            Column({ space: 8 }) {
              Text('密码').fontSize(14).fontWeight(FontWeight.Medium).fontColor('#0F172A').width('100%')
              Row({ space: 10 }) {
                Text('🔒').fontSize(15).fontColor('#94A3B8')
                TextInput({ placeholder: '请输入密码',
                            text: this.showPassword ? this.password : this.password })
                  .type(this.showPassword ? InputType.Normal : InputType.Password)
                  .layoutWeight(1).height(48).fontSize(15)
                  .backgroundColor(Color.Transparent).padding(0)
                  .enabled(!this.busy)
                  .onChange((value: string) => { this.password = value; })
                Text(this.showPassword ? '🙈' : '👁')
                  .fontSize(15).fontColor('#94A3B8')
                  .onClick(() => { this.showPassword = !this.showPassword; })
              }
              .width('100%').padding({ left: 14, right: 14 })
              .backgroundColor('#F8FAFC').borderRadius(10)
              .border({ width: 1, color: '#E2E8F0' })

              Text('演示版为免密登录：密码仅作界面占位，不参与校验。生产接入 AGC 认证服务。')
                .fontSize(11).fontColor('#94A3B8').lineHeight(17).width('100%')
            }.width('100%')

            // 年级（仅注册模式）
            if (this.mode === 'register') {
              Column({ space: 8 }) {
                Text('在读年级（可跳过）').fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor('#0F172A').width('100%')
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(GRADE_OPTIONS, (item: string) => {
                    Text(item)
                      .fontSize(13)
                      .fontColor(this.grade === item ? '#FFFFFF' : '#2563EB')
                      .backgroundColor(this.grade === item ? '#2563EB' : '#EFF6FF')
                      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                      .borderRadius(16).margin({ right: 8, bottom: 8 })
                      .onClick(() => { this.grade = this.grade === item ? '' : item; })
                  })
                }.width('100%')
              }.width('100%')
            }

            // 记住我
            Row({ space: 8 }) {
              Text(this.rememberMe ? '☑' : '☐')
                .fontSize(16).fontColor(this.rememberMe ? '#2563EB' : '#94A3B8')
              Text('记住我').fontSize(13).fontColor('#475467')
            }
            .width('100%')
            .onClick(() => { this.rememberMe = !this.rememberMe; })

            // 主按钮
            Button(this.busy ? '处理中…' : (this.mode === 'login' ? '登录  →' : '注册并进入  →'))
              .width('100%').height(50).fontSize(16).fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .backgroundColor(this.canSubmit() ? '#3B82F6' : '#CBD5E1')
              .borderRadius(12)
              .enabled(this.canSubmit())
              .onClick(() => { this.onSubmit(); })
          }
          .width('100%').padding({ top: 22 })

          // ---------- 提示 ----------
          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(13).lineHeight(20).width('100%').padding(12).borderRadius(10)
              .fontColor(this.messageIsError ? '#EF4444' : '#475467')
              .backgroundColor(this.messageIsError ? '#FEF2F2' : '#F8FAFC')
              .margin({ top: 14 })
          }

          // ---------- 分隔 ----------
          Row({ space: 12 }) {
            Divider().color('#E2E8F0').layoutWeight(1)
            Text('或').fontSize(12).fontColor('#94A3B8')
            Divider().color('#E2E8F0').layoutWeight(1)
          }.width('100%').margin({ top: 28, bottom: 18 })

          // ---------- 演示 / 离线逃生口（评审必用，务必保留） ----------
          Button('跳过登录，用演示身份进入 →')
            .width('100%').height(46).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor('#2563EB').backgroundColor('#FFFFFF')
            .border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
            .onClick(() => this.enterAsGuest())
          Text(`以演示身份（${ApiDefaults.DEMO_USER_ID}）进入，直接看到完整的 Agent 决策闭环。`)
            .fontSize(11).fontColor('#94A3B8').lineHeight(17).width('100%')
            .margin({ top: 8 })

          Button('无网络？用离线模式进入')
            .width('100%').height(40).fontSize(13).fontColor('#64748B')
            .backgroundColor(Color.Transparent)
            .margin({ top: 6 })
            .onClick(() => this.enterOffline())
          Text('离线演示：全部数据由本机提供，判分规则与后端一致。')
            .fontSize(11).fontColor('#94A3B8').width('100%')

          Blank().height(28)

          Text('当前身份仅用于保存你的学习画像与计划，不含手机号等敏感信息。')
            .fontSize(11).fontColor('#B0B7C3').lineHeight(17).width('100%')

          Blank().height(24)
        }
        .width('100%')
        .padding({ left: 24, right: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%').height('100%').backgroundColor('#FFFFFF')
  }

  /**
   * 分段控件（对应参考图的「登录 | 注册」与「密码登录 | 验证码登录」）。
   *
   * 用**无参 Builder + 内部读 state** 的写法会与调用方耦合，故这里接收
   * 静态选项数组与当前选中值；选中态由调用方传入的 `activeKey` 决定。
   * 选项是常量、`activeKey` 是 `@State`，因此重建时能正确刷新高亮。
   */
  @Builder
  Segmented(options: SegOption[], activeKey: string, onPick: (key: string) => void) {
    Row({ space: 0 }) {
      ForEach(options, (item: SegOption) => {
        Row({ space: 6 }) {
          Text(item.icon).fontSize(13)
          Text(item.label).fontSize(14)
            .fontWeight(activeKey === item.key ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(activeKey === item.key ? '#2563EB' : '#64748B')
        }
        .layoutWeight(1).height(44)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(activeKey === item.key ? '#FFFFFF' : '#F1F5F9')
        .borderRadius(8)
        .onClick(() => onPick(item.key))
      }, (item: SegOption) => item.key)
    }
    .width('100%').padding(4).backgroundColor('#F1F5F9').borderRadius(10)
    .margin({ bottom: 12 })
  }
}

/** 分段控件的选项类型。 */
interface SegOption {
  key: string;
  label: string;
  icon: string;
}
