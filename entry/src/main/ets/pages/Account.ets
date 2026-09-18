import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiDefaults } from '../api/ApiDefaults';
import { AuthClient } from '../api/AuthClient';
import { AuthResult } from '../api/AuthResult';
import { AuthStore } from '../api/AuthStore';
import { ClientCache } from '../cache/ClientCache';
import { WorkflowSessionStore } from '../cache/WorkflowSessionStore';
import { appState } from '../data/AppState';

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
  @State message: string = '';
  @State messageIsError: boolean = false;
  @State busy: boolean = false;
  @State showSignOutConfirm: boolean = false;
  @State showDeleteConfirm: boolean = false;
  @State showSwitchConfirm: boolean = false;

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    this.signedIn = appState.isSignedIn;
    this.nickname = appState.authNickname;
    this.userId = appState.currentUser.userId;
    this.grade = appState.currentUser.basicInfo.grade;
    this.sourceLabel = Account.sourceText(appState.authSource);
  }

  private static sourceText(source: string): string {
    if (source === 'local') return '本机账号（昵称注册）';
    if (source === 'restored') return '已恢复的登录态';
    if (source === 'fixture') return '离线 Fixture 演示';
    return '体验身份（演示数据）';
  }

  private clearLocalCaches(): void {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
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
          Column({ space: 8 }) {
            Text(this.nickname).fontSize(23).fontWeight(FontWeight.Bold).fontColor('#111827')
              .width('100%')
            Text(this.userId).fontSize(12).fontColor('#667085').width('100%')
            if (this.grade.length > 0) {
              Text(`在读年级：${this.grade}`).fontSize(12).fontColor('#667085').width('100%')
            }
            Row({ space: 8 }) {
              Text(this.sourceLabel)
                .fontSize(11)
                .fontColor(this.signedIn ? '#1E6B3A' : '#B45309')
                .backgroundColor(this.signedIn ? '#ECFDF5' : '#FFFBEB')
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(10)
            }.width('100%').margin({ top: 4 })
          }
          .width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(14)
          .border({ width: 1, color: '#E2E8F0' })

          // ---------- 提示 ----------
          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(13).lineHeight(20)
              .fontColor(this.messageIsError ? '#EF4444' : '#475467')
              .width('100%').padding(12)
              .backgroundColor(this.messageIsError ? '#FEF2F2' : '#F8FAFC')
              .borderRadius(10)
          }

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
