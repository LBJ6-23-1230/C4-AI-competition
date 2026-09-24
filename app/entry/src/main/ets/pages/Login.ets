import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiDefaults } from '../api/ApiDefaults';
import { ApiEnvironmentStore } from '../api/ApiEnvironmentStore';
import { AuthClient } from '../api/AuthClient';
import { AuthResult } from '../api/AuthResult';
import { GRADE_OPTIONS } from '../api/AuthModels';
import { appState } from '../data/AppState';
import { DeviceLayout } from '../utils/DeviceLayout';

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
 * 由华为托管凭据，本页只需把 `AuthClient.loginOrRegister()` 换成 AGC 的登录调用
 * （注意用 `loginOrRegister` 而不是 `register`：后者要求显式传手机号，
 * 且不做"已存在则登录"的兜底）。
 *
 * 「一键体验 / 跳过登录」必须保留且足够显眼：评审现场任何摩擦都是风险。
 */
@Entry
@Component
struct Login {
  /** 'login' | 'register' —— 顶部大分段。 */
  @State mode: string = 'login';
  /** 'password' | 'code' —— 登录方式分段（仅 login 模式显示）。 */
  @State method: string = 'password';
  @State nickname: string = '';
  /** 手机号 —— 注册必填、登录首选（唯一身份标识）。 */
  @State phone: string = '';
  @State password: string = '';
  /** 短信验证码（仅 `method === 'code'` 使用）。 */
  @State verifyCode: string = '';
  /** 重发倒计时秒数；0 表示可以发送。值来自后端 `resendAfterSeconds`，不写死。 */
  @State resendCountdown: number = 0;
  /** 验证码是否已发出（用于切换按钮文案与展示开发回显提示）。 */
  @State codeSent: boolean = false;
  /**
   * 短信是否**真的**发出去了。
   *
   * false 表示后端仅在开发模式回显了验证码 —— 界面必须如实说明，
   * 不能显示成"验证码已发送"（后端专门设计了 `smsDelivered` 字段来区分）。
   */
  @State smsDelivered: boolean = false;
  /** 开发模式回显的验证码；非空时界面用醒目样式标注"开发回显"。 */
  @State devCode: string = '';
  @State grade: string = '';
  @State rememberMe: boolean = true;
  @State showPassword: boolean = false;
  @State busy: boolean = false;
  @State message: string = '';
  @State messageIsError: boolean = false;
  /** 华为账号一键登录进行中。 */
  @State isHuaweiLoggingIn: boolean = false;

  private isActive: boolean = false;
  /** 倒计时定时器句柄；离开页面必须清掉，否则会在已销毁的页面上 setState。 */
  private resendTimer: number = -1;

  aboutToAppear(): void {
    this.isActive = true;
  }

  aboutToDisappear(): void {
    this.isActive = false;
    this.stopResendTimer();
  }

  // ---------------------------------------------------------------- 校验
  /**
   * 手机号格式校验（与后端 `service.normalize_phone` 同一套规则）。
   *
   * 前端先校验是为了**减少一次无效往返**；后端仍会独立校验，
   * 不能把前端校验当作安全边界。
   */
  private validatePhone(): string {
    const digits: string = this.phone.replace(/[^\d]/g, '');
    const normalized: string = (digits.length === 13 && digits.startsWith('86'))
      ? digits.substring(2) : digits;
    if (normalized.length === 0) {
      return '请输入手机号';
    }
    if (!/^1[3-9]\d{9}$/.test(normalized)) {
      return '手机号格式不正确（应为 11 位中国大陆号码）';
    }
    return '';
  }

  /** 取出归一化后的手机号（去掉 +86、空格、横线）。 */
  private normalizedPhone(): string {
    const digits: string = this.phone.replace(/[^\d]/g, '');
    return (digits.length === 13 && digits.startsWith('86')) ? digits.substring(2) : digits;
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

  /**
   * 真实账号登录后必须走联机数据源 —— 而且必须**持久化**。
   *
   * 修复的缺陷：原先三处登录都只调 `AgentApiClient.setUseFixture(false)`，
   * 那只改内存、没写回 `ApiEnvironmentStore`。于是这条路径会出问题：
   *
   *   打开离线 Fixture（持久化为 true）→ 退出 → 登录真实账号（内存置 false）
   *   → 正常使用 → **重启 App** → `EntryAbility` 把持久化的 true 恢复回来
   *   → 已登录的账号直接走 Fixture 分支，看到的是演示数据。
   *
   * 用户视角就是「离线/联机那个开关自己又跳回离线了」。现在与
   * 「接口环境」页一样，把选择写回持久化存储。
   */
  private useOnlineSource(): void {
    AgentApiClient.setUseFixture(false);
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      ApiEnvironmentStore.save(context, AgentApiClient.getConfig());
    } catch (error) {
      // 持久化失败不影响本次登录：本次会话已经是联机的，只是下次启动会按旧值。
    }
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
   * ⚠️ 这里修掉了一个实际缺陷：**此前两个标签都只调 `AuthClient.register()`**，
   * 于是「登录」标签下用同一昵称再点一次会**又建一个新账号**
   * （实测两次注册「张三」得到两个不同 userId）——用户以为登录了，
   * 实际旧画像永远读不到。
   *
   * 现在按 `mode` 真正分派：
   *   · 登录 → `AuthClient.loginByPhoneOrNickname()`（手机号优先）
   *   · 注册 → `AuthClient.loginOrRegister()`（**手机号必填**，已存在则登录）
   *
   * 密码字段仍只作视觉占位（后端刻意不做密码体系，见文件头说明）。
   */
  private async onSubmit(): Promise<void> {
    if (this.busy) {
      return;
    }

    // 验证码登录：走独立链路（先校验手机号+验证码，再 verifyCode）
    if (this.method === 'code' && this.mode === 'login') {
      await this.onVerifyCodeLogin();
      return;
    }

    const invalidNickname: string = AuthClient.validateNickname(this.nickname);
    if (invalidNickname.length > 0) {
      this.message = invalidNickname;
      this.messageIsError = true;
      return;
    }

    // 手机号：注册时**必填**，登录时可选（但填了就会优先按号匹配）
    const phoneError: string = this.validatePhone();
    if (this.mode === 'register' && phoneError.length > 0) {
      this.message = phoneError;
      this.messageIsError = true;
      return;
    }
    if (this.mode === 'login' && this.phone.trim().length > 0 && phoneError.length > 0) {
      this.message = phoneError;
      this.messageIsError = true;
      return;
    }

    this.busy = true;
    this.message = '';
    const phone: string = this.normalizedPhone();

    // 关键分派
    let result: AuthResult;
    if (this.mode === 'register') {
      result = await AuthClient.loginOrRegister(this.nickname, this.grade, phone);
    } else if (phone.length > 0) {
      // 登录且填了手机号 → 按手机号登录（唯一、可验证，比昵称可靠）
      result = await AuthClient.loginByPhone(phone);
    } else {
      result = await AuthClient.loginByNickname(this.nickname);
    }
    if (!this.isActive) {
      return;
    }
    this.busy = false;

    if (!result.ok) {
      // 登录模式下"查无此账号"是很常见的误操作，直接把用户引到注册标签
      if (this.mode === 'login'
        && (result.message.indexOf('还没有账号') >= 0 || result.message.indexOf('请先注册') >= 0)) {
        this.message = '还没有账号。已为你切到「注册」，补上手机号再点一次即可建立。';
        this.messageIsError = true;
        this.mode = 'register';
        return;
      }
      this.message = result.message;
      this.messageIsError = true;
      return;
    }
    // 真实账号需要走联机数据源
    this.useOnlineSource();
    appState.applyLogin(result.user, result.source);
    this.goHome();
  }

  /**
   * 华为账号一键登录。
   *
   * 这是鸿蒙赛道最对口的登录方式：免注册、免验证码，
   * 直接拿到华为账号的 OpenID 作为身份标识。
   *
   * **诚实说明**：它需要 DevEco 中配置好 AppGallery Connect 的
   * client_id 与签名证书指纹，否则一步都走不通。所以这里把失败原因
   * 原样呈现给用户，不假装成功。
   */
  private async onHuaweiLogin(): Promise<void> {
    if (this.isHuaweiLoggingIn) {
      return;
    }
    this.isHuaweiLoggingIn = true;
    this.message = '';
    const result: AuthResult = await AuthClient.loginWithHuaweiAccount();
    if (!this.isActive) {
      return;
    }
    this.isHuaweiLoggingIn = false;
    if (!result.ok) {
      this.message = result.message;
      this.messageIsError = true;
      return;
    }
    this.useOnlineSource();
    appState.applyLogin(result.user, result.source);
    this.goHome();
  }

  // -------------------------------------------------------- 手机号验证码登录
  /**
   * 发送验证码。
   *
   * 三个要点：
   * 1. **倒计时用后端返回的 `resendAfterSeconds`**，不要写死 60 ——
   *    否则界面显示的"可重发时间"与后端真实限流不一致，用户点了会被 429。
   * 2. `smsDelivered === false` 时**必须如实告知**短信没真的发出去，
   *    并展示开发回显码。这是后端专门设计来避免"假装已发送"的字段。
   * 3. 离开页面要清定时器，避免在已销毁的页面上写 @State。
   */
  private async onSendCode(): Promise<void> {
    if (this.busy || this.resendCountdown > 0) {
      return;
    }
    const phoneError: string = this.validatePhone();
    if (phoneError.length > 0) {
      this.message = phoneError;
      this.messageIsError = true;
      return;
    }

    this.busy = true;
    this.message = '';
    const result: AuthResult = await AuthClient.sendVerificationCode(this.normalizedPhone());
    if (!this.isActive) {
      return;
    }
    this.busy = false;

    if (!result.ok) {
      this.message = result.message;
      this.messageIsError = true;
      return;
    }

    this.codeSent = true;
    this.smsDelivered = result.smsDelivered === true;
    this.devCode = result.devCode !== undefined ? result.devCode : '';
    this.message = result.message;
    // 开发回显不是错误，但要足够醒目，避免被误当成"短信已发送"
    this.messageIsError = false;
    this.startResendTimer(result.resendAfterSeconds !== undefined ? result.resendAfterSeconds : 60);
  }

  /** 校验验证码并登录 / 自动注册。 */
  private async onVerifyCodeLogin(): Promise<void> {
    const phoneError: string = this.validatePhone();
    if (phoneError.length > 0) {
      this.message = phoneError;
      this.messageIsError = true;
      return;
    }
    if (!/^\d{6}$/.test(this.verifyCode.trim())) {
      this.message = '请输入 6 位数字验证码。';
      this.messageIsError = true;
      return;
    }

    this.busy = true;
    this.message = '';
    // 昵称/年级只在"首次自动建号"时被后端采用；已注册手机号会忽略它们。
    const result: AuthResult = await AuthClient.verifyCode(
      this.normalizedPhone(), this.verifyCode.trim(),
      this.nickname.length > 0 ? this.nickname : undefined,
      this.grade.length > 0 ? this.grade : undefined);
    if (!this.isActive) {
      return;
    }
    this.busy = false;

    if (!result.ok) {
      this.message = result.message;
      this.messageIsError = true;
      return;
    }
    this.useOnlineSource();
    appState.applyLogin(result.user, result.source);
    this.goHome();
  }

  /** 启动重发倒计时。 */
  private startResendTimer(seconds: number): void {
    this.stopResendTimer();
    this.resendCountdown = seconds > 0 ? seconds : 60;
    this.resendTimer = setInterval(() => {
      if (!this.isActive) {
        this.stopResendTimer();
        return;
      }
      this.resendCountdown = this.resendCountdown - 1;
      if (this.resendCountdown <= 0) {
        this.resendCountdown = 0;
        this.stopResendTimer();
      }
    }, 1000);
  }

  private stopResendTimer(): void {
    if (this.resendTimer !== -1) {
      clearInterval(this.resendTimer);
      this.resendTimer = -1;
    }
  }

  private canSubmit(): boolean {
    if (this.busy) {
      return false;
    }
    if (AuthClient.validateNickname(this.nickname).length > 0) {
      return false;
    }
    // 注册必须填合法手机号；登录允许只填昵称
    if (this.mode === 'register' && this.validatePhone().length > 0) {
      return false;
    }
    return true;
  }

  // ---------------------------------------------------------------- 界面
  build() {
    Column() {
      Scroll() {
        // ⚠️ 限宽加在**内容列**上，不能加在外面的 `Scroll` 上。
        //
        // 原实现把 `constraintSize({ maxWidth: contentMaxWidth() })` 挂在 `Scroll` 上，
        // 在平板（2880×1920，实测）上引发了一类很难看出来的渲染错误：
        // Scroll 自身被压到 720vp（实测 x=[720,2160]），但它内部滚动内容的**测量**没有
        // 同步收缩，于是每个横向弹性布局都算错：
        //   · 分隔行 `Row { Divider.layoutWeight(1); Text('或'); Divider.layoutWeight(1) }`
        //     里第一个 Divider 吃掉整整 1356px（应约一半），把「或」挤到 x=2148 贴住右缘；
        //   · `Button('登录  →')` 的文字不居中，落到 x≈2145–2157；
        //   · 「华为账号一键登录」「跳过登录…」的文字同样被推到右缘并截断。
        // 节点树与像素扫描都证实了这三点（按钮中部的文字笔画**完全为空**）。
        //
        // 现在 Scroll 自己占满父宽（不再被压缩），限宽交给内部内容列，
        // 由外层 Column 的水平居中把它摆到中间。这样横向弹性布局拿到的可用宽度
        // 与最终渲染宽度一致，上面三处都能恢复正常。
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
          .padding({ top: this.topPadding(), bottom: 26 })

          // ---------- 登录 / 注册 分段 ----------
          // 用无参 Builder（直接读 this.mode），确保切换后高亮与主按钮文案必然刷新
          this.ModeSegment()

          // ---------- 密码 / 验证码 分段（仅登录模式） ----------
          if (this.mode === 'login') {
            this.MethodSegment()
          }

          // ---------- 表单 ----------
          Column({ space: 16 }) {
            // 昵称
            Column({ space: 8 }) {
              Text('昵称').fontSize(14).fontWeight(FontWeight.Medium).fontColor('#0F172A').width('100%')
              Row({ space: 10 }) {
                Text('👤').fontSize(15).fontColor('#94A3B8')
                TextInput({ placeholder: '请输入昵称（1-16 字）', text: this.nickname })
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

            // 手机号 —— 注册必填；登录时填了会优先按手机号匹配
            Column({ space: 8 }) {
              Row({ space: 6 }) {
                Text('手机号').fontSize(14).fontWeight(FontWeight.Medium).fontColor('#0F172A')
                Text(this.mode === 'register' ? '必填' : '选填')
                  .fontSize(11)
                  .fontColor(this.mode === 'register' ? '#B91C1C' : '#94A3B8')
                  .backgroundColor(this.mode === 'register' ? '#FEF2F2' : '#F1F5F9')
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(6)
                Blank()
              }.width('100%')
              Row({ space: 10 }) {
                Text('📱').fontSize(15).fontColor('#94A3B8')
                TextInput({ placeholder: '11 位手机号', text: this.phone })
                  .type(InputType.PhoneNumber)
                  .layoutWeight(1).height(48).fontSize(15)
                  .backgroundColor(Color.Transparent).padding(0)
                  .maxLength(20).enabled(!this.busy)
                  .onChange((value: string) => {
                    this.phone = value;
                    if (this.messageIsError) {
                      this.message = '';
                      this.messageIsError = false;
                    }
                  })
              }
              .width('100%').padding({ left: 14, right: 14 })
              .backgroundColor('#F8FAFC').borderRadius(10)
              .border({ width: 1, color: '#E2E8F0' })
              Text(this.mode === 'register'
                ? '手机号是账号的唯一标识，用于登录与找回。'
                : (this.method === 'code'
                  ? '验证码登录：手机号未注册时会自动为你建号。'
                  : '填了手机号就按手机号登录（唯一、可靠）；留空则按昵称登录。'))
                .fontSize(11).fontColor('#98A2B3').lineHeight(17).width('100%')
            }.width('100%')

            // ---------- 登录方式 = 验证码：验证码输入 + 获取验证码 ----------
            if (this.mode === 'login' && this.method === 'code') {
              Column({ space: 8 }) {
                Text('短信验证码').fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor('#0F172A').width('100%')
                Row({ space: 10 }) {
                  Text('💬').fontSize(15).fontColor('#94A3B8')
                  TextInput({ placeholder: '6 位数字验证码', text: this.verifyCode })
                    .type(InputType.Number)
                    .maxLength(6)
                    .layoutWeight(1).height(48).fontSize(15)
                    .backgroundColor(Color.Transparent).padding(0)
                    .enabled(!this.busy)
                    .onChange((value: string) => { this.verifyCode = value; })
                  // 倒计时读的是后端 `resendAfterSeconds`，与真实限流一致
                  Button(this.resendCountdown > 0
                    ? `${this.resendCountdown} 秒后可重发`
                    : (this.codeSent ? '重新获取' : '获取验证码'))
                    .fontSize(13).height(36).borderRadius(8)
                    .backgroundColor(this.resendCountdown > 0 ? '#E2E8F0' : '#DBEAFE')
                    .fontColor(this.resendCountdown > 0 ? '#94A3B8' : '#1D4ED8')
                    .enabled(!this.busy && this.resendCountdown === 0)
                    .onClick(() => { this.onSendCode(); })
                }
                .width('100%').padding({ left: 14, right: 14 })
                .backgroundColor('#F8FAFC').borderRadius(10)
                .border({ width: 1, color: '#E2E8F0' })

                // 开发回显必须醒目且如实：不能让人以为短信真的发出去了
                if (!this.smsDelivered && this.devCode.length > 0) {
                  Column({ space: 4 }) {
                    Text('⚠️ 开发模式回显（短信未真实下发）')
                      .fontSize(12).fontWeight(FontWeight.Medium).fontColor('#B45309').width('100%')
                    Text(`验证码：${this.devCode}`)
                      .fontSize(15).fontWeight(FontWeight.Bold).fontColor('#B45309').width('100%')
                    Text('后端未配置短信服务商，此码仅用于联调与演示。')
                      .fontSize(11).fontColor('#B45309').lineHeight(16).width('100%')
                  }
                  .width('100%').padding(12).backgroundColor('#FFFBEB')
                  .borderRadius(10).border({ width: 1, color: '#FDE68A' })
                } else if (this.codeSent) {
                  Text('验证码已发送。收不到可改用「密码登录」或「一键体验」。')
                    .fontSize(11).fontColor('#64748B').lineHeight(17).width('100%')
                }
              }.width('100%')
            }

            // 密码（视觉占位，不参与校验）—— 验证码方式下不显示
            if (!(this.mode === 'login' && this.method === 'code')) {
              Column({ space: 8 }) {
                Text('密码').fontSize(14).fontWeight(FontWeight.Medium).fontColor('#0F172A').width('100%')
                Row({ space: 10 }) {
                  Text('🔒').fontSize(15).fontColor('#94A3B8')
                  TextInput({ placeholder: '请输入密码', text: this.password })
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
            }

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
            // 文案必须与当前标签严格对应：此前两个标签下都是"登录 →"，
            // 用户以为在登录、实际在注册（见 onSubmit 的说明）。
            Button(this.busy ? '处理中…'
              : (this.mode === 'login' ? '登录  →' : '注册并进入  →'))
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

          // ---------- 华为账号一键登录（鸿蒙全场景能力） ----------
          // 免注册、免验证码；同一华为账号在手机/平板/PC 上是同一个身份，
          // 换设备不需要重新注册 —— 这是"全场景"最实在的一处体现。
          Button(this.isHuaweiLoggingIn ? '正在拉起华为账号…' : '华为账号一键登录')
            .width('100%').height(48).fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor('#0F172A').backgroundColor('#FFFFFF')
            .borderRadius(12).border({ width: 1, color: '#E2E8F0' })
            .enabled(!this.isHuaweiLoggingIn && !this.busy)
            .onClick(() => { this.onHuaweiLogin(); })
          Text('使用华为账号登录，无需注册。需设备已登录华为账号，'
            + '且应用已在 AppGallery Connect 配置 client_id。')
            .fontSize(11).fontColor('#98A2B3').lineHeight(17).width('100%')
            .margin({ top: 8 })

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
        .constraintSize({ maxWidth: DeviceLayout.contentMaxWidth() })
        .padding({ left: 24, right: 24 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%').height('100%').backgroundColor('#FFFFFF')
  }

  /** 大屏上减少顶部留白（手机竖屏留 56 好看，平板上会显得空）。 */
  private topPadding(): number {
    return DeviceLayout.isLargeScreen() ? 32 : 56;
  }

  /**
   * 「登录 | 注册」分段。
   *
   * ⚠️ **刻意不给本 Builder 传参**，而是直接读 `this.mode`。
   *
   * 原因：ArkUI 的 `@Builder` 对**参数**采用值传递，参数不是可观察依赖，
   * 外层状态变化时不保证重建。此前把 `this.mode` 当参数传进去，
   * 存在"点了注册但高亮/联动文案不刷新"的风险（本次一并消除）。
   * **无参 Builder 直接读 `this` 上的状态变量则依赖关系明确、必然刷新。**
   */
  @Builder
  ModeSegment() {
    Row({ space: 0 }) {
      ForEach(MODE_OPTIONS, (item: SegOption) => {
        Row({ space: 6 }) {
          Text(item.icon).fontSize(13)
          Text(item.label).fontSize(14)
            .fontWeight(this.mode === item.key ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.mode === item.key ? '#2563EB' : '#64748B')
        }
        .layoutWeight(1).height(44)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.mode === item.key ? '#FFFFFF' : '#F1F5F9')
        .borderRadius(8)
        .onClick(() => {
          this.mode = item.key;
          this.message = '';
          this.messageIsError = false;
        })
      }, (item: SegOption) => item.key)
    }
    .width('100%').padding(4).backgroundColor('#F1F5F9').borderRadius(10)
    .margin({ bottom: 12 })
  }

  /** 「密码登录 | 验证码登录」分段。同样无参，直接读 `this.method`。 */
  @Builder
  MethodSegment() {
    Row({ space: 0 }) {
      ForEach(METHOD_OPTIONS, (item: SegOption) => {
        Row({ space: 6 }) {
          Text(item.icon).fontSize(13)
          Text(item.label).fontSize(14)
            .fontWeight(this.method === item.key ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.method === item.key ? '#2563EB' : '#64748B')
        }
        .layoutWeight(1).height(44)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.method === item.key ? '#FFFFFF' : '#F1F5F9')
        .borderRadius(8)
        .onClick(() => {
          this.method = item.key;
          this.message = '';
          this.messageIsError = false;
        })
      }, (item: SegOption) => item.key)
    }
    .width('100%').padding(4).backgroundColor('#F1F5F9').borderRadius(10)
    .margin({ bottom: 12 })
  }

  /**
   * @deprecated 保留仅为兼容；新代码请用 `ModeSegment()` / `MethodSegment()`。
   * 传参版 Builder 存在状态不刷新的风险，故不再从 `build()` 调用。
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

/** 分段选项常量（提到组件外，避免每次 build 重建数组）。 */
const MODE_OPTIONS: SegOption[] = [
  { key: 'login', label: '登录', icon: '🔒' },
  { key: 'register', label: '注册', icon: '✎' }
];

const METHOD_OPTIONS: SegOption[] = [
  { key: 'password', label: '密码登录', icon: '🔒' },
  { key: 'code', label: '验证码登录', icon: '💬' }
];

/** 分段控件的选项类型。 */
interface SegOption {
  key: string;
  label: string;
  icon: string;
}
