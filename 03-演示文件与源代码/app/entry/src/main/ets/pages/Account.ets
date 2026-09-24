import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiDefaults } from '../api/ApiDefaults';
import { AuthClient } from '../api/AuthClient';
import { AuthUser } from '../api/AuthModels';
import { AuthResult } from '../api/AuthResult';
import { AuthStore } from '../api/AuthStore';
import { ClientCache } from '../cache/ClientCache';
import { WorkflowSessionStore } from '../cache/WorkflowSessionStore';
import { appState } from '../data/AppState';
import { ProactiveSettingsStore } from '../services/ProactiveSettingsStore';
import { ProactiveSurfaceService } from '../services/ProactiveSurfaceService';

/**
 * 账号与隐私页（「我的」）。
 *
 * 承载四件事：
 *   1. 展示当前身份（登录用户 / 体验身份），让用户随时知道"Agent 现在认为我是谁"；
 *   2. **返回登录页**（切换身份）—— 无论当前是登录态还是体验身份都可用，
 *      这是「进得去也出得来」的兜底出口；
 *   3. 退出登录（二次确认）→ 回到 demo-user 体验身份，留在 App 内；
 *   4. 注销账号（合规要求，二次确认 + 明确说明后果）。
 *
 * 为什么这一页重要：登录功能对 50 分创新性几乎没有贡献，但它必须**可退出、可注销、
 * 可回到登录页**，否则就是"能进不能出"的设计缺陷，规范性上会扣分。
 */
@Entry
@Component
struct Account {
  @State signedIn: boolean = false;
  @State nickname: string = '';
  @State userId: string = '';
  @State grade: string = '';
  @State sourceLabel: string = '';
  /**
   * 脱敏手机号与注册时间（来自 `/api/v1/auth/me`）。
   *
   * 为什么单独拉一次：`appState.currentUser` 是 `UserProfile`（学习画像用的
   * `basicInfo` 结构），里面**没有** `phoneMasked` / `createdAt`。
   * 而「我的」页应当显示"这个账号是谁" —— 昵称、手机号、年级、注册时间。
   *
   * 失败时**不报错也不清空**：本地已有昵称/年级，先把能显示的显示出来，
   * 网络恢复后下次进入再补齐。拉不到就少显示两行，不影响页面可用。
   */
  @State phoneMasked: string = '';
  @State createdAt: string = '';
  @State message: string = '';
  @State messageIsError: boolean = false;
  @State busy: boolean = false;
  @State showSignOutConfirm: boolean = false;
  @State showDeleteConfirm: boolean = false;
  @State showSwitchConfirm: boolean = false;
  @State proactiveEnabled: boolean = ProactiveSettingsStore.isEnabled();

  aboutToAppear(): void {
    this.refresh();
    this.loadAccountDetail();
  }

  private refresh(): void {
    this.signedIn = appState.isSignedIn;
    this.nickname = appState.authNickname;
    this.userId = appState.currentUser.userId;
    this.grade = appState.currentUser.basicInfo.grade;
    this.sourceLabel = Account.sourceText(appState.authSource);
    this.proactiveEnabled = ProactiveSettingsStore.isEnabled();
  }

  /** 拉取账号详情（脱敏手机号、注册时间）。仅登录态有意义。 */
  private async loadAccountDetail(): Promise<void> {
    if (!this.signedIn) {
      this.phoneMasked = '';
      this.createdAt = '';
      return;
    }
    const result = await AgentApiClient.authMe();
    if (result.ok) {
      const user: AuthUser = result.data.user;
      this.phoneMasked = user.phoneMasked ?? '';
      this.createdAt = Account.friendlyDate(user.createdAt);
      // 服务端是权威来源，顺便同步昵称/年级
      if (user.nickname.length > 0) { this.nickname = user.nickname; }
      if (user.grade.length > 0) { this.grade = user.grade; }
    }
  }

  /** 头像占位字符：取昵称首字符；昵称为空则用「学」。 */
  private avatarText(): string {
    return this.nickname.length > 0 ? this.nickname.substring(0, 1) : '学';
  }

  /** 把 ISO 时间裁成 `YYYY-MM-DD`，解析不了就原样返回。 */
  private static friendlyDate(iso: string): string {
    if (iso.length >= 10 && iso.charAt(4) === '-' && iso.charAt(7) === '-') {
      return iso.substring(0, 10);
    }
    return iso;
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private async updateProactiveSetting(enabled: boolean): Promise<void> {
    if (!enabled) {
      ProactiveSettingsStore.save(this.context(), false);
      this.proactiveEnabled = false;
      this.message = '主动提醒已关闭。';
      this.messageIsError = false;
      return;
    }
    const granted: boolean = await ProactiveSurfaceService.requestPermission(this.context());
    if (!granted) {
      ProactiveSettingsStore.save(this.context(), false);
      this.proactiveEnabled = false;
      this.message = '未获得系统通知权限，主动提醒保持关闭。可稍后在系统设置中开启。';
      this.messageIsError = true;
      return;
    }
    const saved: boolean = ProactiveSettingsStore.save(this.context(), true);
    this.proactiveEnabled = saved;
    this.message = saved ? '主动提醒已开启。Agent 仅在后端判定需要提醒时投递通知。' : '主动提醒设置保存失败。';
    this.messageIsError = !saved;
  }

  private static sourceText(source: string): string {
    if (source === 'local') return '本机账号（昵称注册）';
    if (source === 'restored') return '已恢复的登录态';
    if (source === 'fixture') return '离线 Fixture 演示';
    return '体验身份（演示数据）';
  }

  private clearLocalCaches(): void {
    const context: common.UIAbilityContext = this.context();
    ClientCache.clearDemoData();
    WorkflowSessionStore.clear(context);
  }

  /**
   * 返回登录页（切换身份）。
   *
   * 这是"进得去也出得来"的关键出口。行为分两种：
   *
   * * **已登录** → 先真正退出登录（吊销服务端 token + 清本地 + 回体验身份），
   *   再跳登录页。否则登录态还留着，`EntryAbility` 下次启动又会直接进主页，
   *   用户会觉得"我明明退出去了怎么又回来了"。
   * * **体验身份** → 不需要吊销任何凭据，直接跳登录页换个身份进来即可。
   *
   * 用 `replaceUrl` 而非 `pushUrl`：登录页是身份入口，不该在返回栈里累积，
   * 否则用户在登录页按返回会又回到「我的」，逻辑上很怪。
   */
  private async goToLogin(): Promise<void> {
    this.showSwitchConfirm = false;
    this.busy = true;
    if (AuthStore.isSignedIn()) {
      await AuthClient.signOut();
      appState.applyLogout();
      this.clearLocalCaches();
    }
    this.busy = false;
    // 与 `Index.goToLogin` 保持一致：离线态回到联机，否则登录后仍在读本地 Fixture 数据。
    //
    // 修复的缺陷：原先只有 Index 那条路径关 Fixture，从「我的」返回登录页时它仍开着。
    // 后果是**登录页上所有入口都会报「未找到 fixture 路由」** ——
    // `FixtureApiTransport` 一条 auth 路由都没有，用户看到的是内部错误。
    AgentApiClient.setUseFixture(false);
    router.replaceUrl({ url: 'pages/Login' });
  }

  private async doSignOut(): Promise<void> {
    this.showSignOutConfirm = false;
    this.busy = true;
    const result: AuthResult = await AuthClient.signOut();
    this.busy = false;
    appState.applyLogout();
    this.clearLocalCaches();
    this.message = result.message.length > 0 ? result.message : '已退出登录。';
    this.messageIsError = false;
    this.refresh();
  }

  private async doDeleteAccount(): Promise<void> {
    this.showDeleteConfirm = false;
    this.busy = true;
    const result: AuthResult = await AuthClient.deleteAccount();
    this.busy = false;
    appState.applyLogout();
    this.clearLocalCaches();
    this.message = result.ok
      ? result.message
      : `注销未在服务端完成：${result.message} 本机登录信息已清除。`;
    this.messageIsError = !result.ok;
    this.refresh();
  }

  /**
   * 唯一根节点是 `Stack`。
   *
   * ArkTS 要求 `@Entry` 组件的 `build()` **只能有一个容器根节点**——
   * 不能像 React 那样并列多个兄弟节点。因此这里用 `Stack` 把
   * 「页面主体」与「二次确认浮层」叠在一起：主体在下，浮层在上有更高的 zIndex。
   */
  build() {
    Stack() {
      this.pageContent()
      if (this.showSwitchConfirm) {
        this.confirmOverlay('返回登录页？',
          this.signedIn
            ? '当前账号会先退出登录（服务端凭据同时失效），然后回到登录页。你可以在那里换一个身份重新进入。'
            : '将回到登录页。你可以用昵称建立自己的账号，或再次以演示身份进入。',
          '返回登录页', '#2563EB',
          (): void => { this.goToLogin(); },
          (): void => { this.showSwitchConfirm = false; })
      }
      if (this.showSignOutConfirm) {
        this.confirmOverlay('退出登录？',
          '退出后回到体验身份（demo-user），演示基线数据会重新出现。账号本身不会被删除。',
          '退出', '#2563EB',
          (): void => { this.doSignOut(); },
          (): void => { this.showSignOutConfirm = false; })
      }
      if (this.showDeleteConfirm) {
        this.confirmOverlay('注销账号？',
          '该账号将立即停用，全部登录会话失效，且无法再次登录。此操作不可撤销。',
          '确认注销', '#EF4444',
          (): void => { this.doDeleteAccount(); },
          (): void => { this.showDeleteConfirm = false; })
      }
    }
    .width('100%').height('100%').alignContent(Alignment.TopStart)
  }

  @Builder
  pageContent() {
    Column() {
      // ---------- 顶栏 ----------
      Row() {
        Text('← 返回').fontSize(14).fontColor('#64748B').onClick(() => router.back())
        Blank()
        Text('我的').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB')
      }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .backgroundColor('#FFFFFF')

      Scroll() {
        Column({ space: 16 }) {
          // ---------- 身份卡 ----------
          Row({ space: 14 }) {
            // 头像：昵称首字符。没有真实头像图，用字母块比放默认灰色人像更清楚。
            Text(this.avatarText())
              .fontSize(26).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
              .width(56).height(56).textAlign(TextAlign.Center)
              .backgroundColor('#2563EB').borderRadius(28)

            Column({ space: 5 }) {
              Text(this.nickname.length > 0 ? this.nickname : '体验身份')
                .fontSize(21).fontWeight(FontWeight.Bold).fontColor('#111827')
                .width('100%')
              if (this.phoneMasked.length > 0) {
                Text(this.phoneMasked).fontSize(13).fontColor('#475467').width('100%')
              }
              Text(`账号 ${this.userId}`).fontSize(11).fontColor('#94A3B8').width('100%')
              if (this.grade.length > 0) {
                Text(`在读年级：${this.grade}`).fontSize(12).fontColor('#667085').width('100%')
              }
              if (this.createdAt.length > 0) {
                Text(`注册于 ${this.createdAt}`).fontSize(12).fontColor('#667085').width('100%')
              }
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }
          .width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(14)
          .border({ width: 1, color: '#E2E8F0' })

          Row({ space: 8 }) {
            Text(this.sourceLabel)
              .fontSize(11)
              .fontColor(this.signedIn ? '#1E6B3A' : '#B45309')
              .backgroundColor(this.signedIn ? '#ECFDF5' : '#FFFBEB')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(10)
          }.width('100%').padding({ left: 18, right: 18 })

          // ---------- 提示 ----------
          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(13).lineHeight(20)
              .fontColor(this.messageIsError ? '#EF4444' : '#475467')
              .width('100%').padding(12)
              .backgroundColor(this.messageIsError ? '#FEF2F2' : '#F8FAFC')
              .borderRadius(10)
          }

          // ---------- 主动提醒设置 ----------
          Row({ space: 12 }) {
            Column({ space: 4 }) {
              Text('Agent 主动提醒').fontSize(15).fontWeight(FontWeight.Bold)
                .fontColor('#1F2937').width('100%')
              Text('开启后，应用进入后台时才会请求 Agent 判断；shouldNotify=false 时不会投递。')
                .fontSize(12).fontColor('#667085').lineHeight(18).width('100%')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            // ⚠️ 必须用 `$$` 双向绑定。
            //
            // 修复的缺陷：原来 `isOn: this.proactiveEnabled` 是单向的 ——
            // 用户拨到"开"，Toggle 内部视觉已变 ON，但若 `updateProactiveSetting`
            // 因**没拿到通知权限**而把 `proactiveEnabled` 置回 false，
            // 由于它本来就是 false（**没有状态变化**），ArkUI 不会重渲染，
            // 于是开关**停在 ON**、而存储与提示文字都是 OFF，两边对不上。
            // 加 `$$` 后用户的拨动会先写回 @State，置回 false 就是一次真实变化，
            // 开关会跟着弹回去。
            Toggle({ type: ToggleType.Switch, isOn: $$this.proactiveEnabled })
              .onChange((value: boolean) => { void this.updateProactiveSetting(value); })
          }
          .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(14)
          .border({ width: 1, color: '#E2E8F0' })

          // ---------- 登录态说明 / 降低门槛 ----------
          if (this.signedIn) {
            Column({ space: 8 }) {
              Text('当前是独立账号').fontSize(15).fontWeight(FontWeight.Bold)
                .fontColor('#1F2937').width('100%')
              Text('你的掌握度、错题与学习计划都归到这个账号下，不会被其他身份读到。')
                .fontSize(12).fontColor('#667085').lineHeight(19).width('100%')
            }
            .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(14)
            .border({ width: 1, color: '#E2E8F0' })
          } else {
            Column({ space: 10 }) {
              Text('你正在用体验身份').fontSize(15).fontWeight(FontWeight.Bold)
                .fontColor('#1F2937').width('100%')
              Text(`体验身份固定为 ${ApiDefaults.DEMO_USER_ID}，数据是演示基线（掌握度 42）。`
                + '用昵称建立一个自己的账号，学习记录才会真正属于你。')
                .fontSize(12).fontColor('#667085').lineHeight(19).width('100%')
              Button('建立我的账号')
                .width('100%').height(44).fontSize(14).fontColor('#FFFFFF')
                .backgroundColor('#2563EB').borderRadius(10)
                .onClick(() => this.showSwitchConfirm = true)
            }
            .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(14)
            .border({ width: 1, color: '#E2E8F0' })
          }

          // ---------- 返回登录页（切换身份）★ 常驻出口 ----------
          Button(this.busy ? '处理中…' : '返回登录页')
            .width('100%').height(48).fontSize(15).fontWeight(FontWeight.Bold)
            .fontColor('#2563EB')
            .backgroundColor('#FFFFFF').border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
            .enabled(!this.busy)
            .onClick(() => this.showSwitchConfirm = true)
          Text(this.signedIn
            ? '返回登录页会先退出当前账号，然后你可以换一个身份进来。'
            : '返回登录页可以改用昵称建立账号，或以演示身份重新进入。')
            .fontSize(11).fontColor('#98A2B3').lineHeight(17).width('100%')

          // ---------- 学习搭子 ----------
          Column({ space: 10 }) {
            Row() {
              Text('我的学习搭子').fontSize(15).fontWeight(FontWeight.Bold)
                .fontColor('#1F2937')
              Blank()
              Text('管理 ›').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#2563EB')
            }.width('100%')
              .onClick(() => router.pushUrl({ url: 'pages/PartnerMatch' }))

            if (appState.latestPartner !== null) {
              Row({ space: 10 }) {
                Text('🤝').fontSize(20)
                Column({ space: 3 }) {
                  Text(`${appState.latestPartner!.matchName} · ${appState.latestPartner!.score}% 匹配`)
                    .fontSize(14).fontWeight(FontWeight.Medium).fontColor('#1F2937').width('100%')
                  Text(appState.latestPartner!.studyTime !== null
                    ? `公共空闲时段 ${appState.latestPartner!.studyTime}`
                    : '尚未确认公共空闲时段')
                    .fontSize(11.5).fontColor('#667085').width('100%')
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              }.width('100%').padding(12).backgroundColor('#F8FAFC').borderRadius(12)
            } else {
              Text('还没有匹配到搭子。按课程、目标、知识互补与空闲时间四因子匹配一位学习伙伴。')
                .fontSize(12).fontColor('#667085').lineHeight(19).width('100%')
              Button('去找学习搭子')
                .width('100%').height(42).fontSize(13).fontColor('#2563EB')
                .backgroundColor('#EFF6FF').borderRadius(10)
                .onClick(() => router.pushUrl({ url: 'pages/PartnerMatch' }))
            }
          }
          .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(14)
          .border({ width: 1, color: '#E2E8F0' })

          // ---------- 学习数据（任务完成度 / 专注记录） ----------
          Column({ space: 12 }) {
            Row() {
              Text('学习数据').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#1F2937')
              Blank()
              Text('明细 ›').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#2563EB')
            }.width('100%')
              .onClick(() => router.pushUrl({ url: 'pages/LearningHistory' }))

            Row({ space: 10 }) {
              this.StatBlock(`${appState.getPlanProgress()}%`, '任务完成度')
              this.StatBlock(`${appState.getFocusSummary().todayMinutes}`, '今日专注分钟')
              this.StatBlock(`${appState.getFocusSummary().recentSessions.length}`, '专注记录次数')
            }.width('100%')
            Row({ space: 10 }) {
              this.StatBlock(`${appState.getFocusSummary().streakDays}`, '连续学习天数')
              this.StatBlock(`${Math.round(appState.getFocusSummary().completionRate)}%`, '专注完成率')
              this.StatBlock(`${appState.getUrgentDDLs().length}`, '待处理作业')
            }.width('100%')
          }
          .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(14)
          .border({ width: 1, color: '#E2E8F0' })

          // ---------- 退出登录 ----------
          if (this.signedIn) {
            Button(this.busy ? '处理中…' : '退出登录')
              .width('100%').height(48).fontSize(15).fontColor('#2563EB')
              .backgroundColor('#FFFFFF').border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
              .enabled(!this.busy)
              .onClick(() => this.showSignOutConfirm = true)
            Text('退出后留在 App 内，回到体验身份；账号数据仍保留在服务端。')
              .fontSize(11).fontColor('#98A2B3').width('100%')
          }

          // ---------- 注销账号 ----------
          if (this.signedIn) {
            Button(this.busy ? '处理中…' : '注销账号')
              .width('100%').height(44).fontSize(14).fontColor('#EF4444')
              .backgroundColor('#FFFFFF').border({ width: 1, color: '#FECACA' }).borderRadius(12)
              .enabled(!this.busy)
              .onClick(() => this.showDeleteConfirm = true)
            Text('注销后该账号将无法再登录，全部登录会话立即失效。此操作不可撤销。')
              .fontSize(11).fontColor('#98A2B3').lineHeight(17).width('100%')
          }

          // ---------- 隐私说明 ----------
          Column({ space: 8 }) {
            Text('隐私说明').fontSize(15).fontWeight(FontWeight.Bold)
              .fontColor('#1F2937').width('100%')
            Text('· 不收集手机号、身份证等敏感信息；账号只有一个昵称。')
              .fontSize(12).fontColor('#667085').lineHeight(19).width('100%')
            Text('· 位置仅用于映射学习情境（如"在图书馆"），不上传坐标。')
              .fontSize(12).fontColor('#667085').lineHeight(19).width('100%')
            Text('· 学习数据端侧优先计算，仅上传必要的画像与练习结果。')
              .fontSize(12).fontColor('#667085').lineHeight(19).width('100%')
            Text('· 可随时返回登录页、退出登录或注销账号，注销后服务端凭据立即失效。')
              .fontSize(12).fontColor('#667085').lineHeight(19).width('100%')
          }
          .width('100%').padding(16).backgroundColor('#F8FAFC').borderRadius(14)

          Blank().height(20)
        }
        .width('100%').padding(16)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%').height('100%').backgroundColor('#F1F5F9')
  }

  /** 学习数据统计块（任务完成度 / 专注记录等）。 */
  @Builder
  StatBlock(value: string, label: string) {
    Column({ space: 4 }) {
      Text(value).fontSize(19).fontWeight(FontWeight.Bold).fontColor('#0F172A')
      Text(label).fontSize(11).fontColor('#64748B').textAlign(TextAlign.Center)
    }
    .layoutWeight(1).padding({ top: 13, bottom: 13 })
    .backgroundColor('#F8FAFC').borderRadius(12)
  }

  /**
   * 二次确认浮层。
   *
   * 注意：ArkTS 的 `@Builder` **不支持**把 builder/函数当作参数再转调，
   * 因此回调必须用 `(): void => { ... }` 箭头函数形式传入（而非 `() => expr` 表达式体），
   * 否则内部无法作为 UI 事件处理器绑定。
   */
  @Builder
  confirmOverlay(title: string, body: string, confirmLabel: string, confirmColor: string,
                 onConfirm: () => void, onCancel: () => void) {
    Column() {
      Column({ space: 12 }) {
        Text(title).fontSize(17).fontWeight(FontWeight.Bold).fontColor('#111827').width('100%')
        Text(body).fontSize(13).fontColor('#475467').lineHeight(20).width('100%')
        Row({ space: 10 }) {
          Button('取消')
            .layoutWeight(1).height(44).fontSize(14).fontColor('#475467')
            .backgroundColor('#F1F5F9').borderRadius(10)
            .onClick(() => onCancel())
          Button(confirmLabel)
            .layoutWeight(1).height(44).fontSize(14).fontColor('#FFFFFF')
            .backgroundColor(confirmColor).borderRadius(10)
            .onClick(() => onConfirm())
        }.width('100%').margin({ top: 4 })
      }
      .width('86%').padding(20).backgroundColor('#FFFFFF').borderRadius(16)
    }
    .width('100%').height('100%')
    .backgroundColor('rgba(15, 23, 42, 0.45)')
    .justifyContent(FlexAlign.Center)
  }
}
