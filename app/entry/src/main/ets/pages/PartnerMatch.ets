import router from '@ohos.router';
import { appState } from '../data/AppState';
import { PartnerMatch as PartnerMatchType, MatchFactor, UserProfile, LearningPlanTask } from '../models/AgentModels';
import { LocalAgentService } from '../services/LocalAgentService';
import { ChatNavigation } from '../services/ChatNavigation';
import { AIFloatButton } from '../components/AIFloatButton';
import { AgentApiClient } from '../api/AgentApiClient';
import {
  PartnerCandidateBasicInfo,
  PartnerCandidateProfile,
  PartnerContact,
  PartnerInvitation,
  PartnerInvitationListResponse,
  PartnerInvitationResponse,
  PartnerMatchFactors,
  PartnerMatchResponse,
  PartnerRankedCandidate
} from '../api/ApiModels';
import { ApiFailure, ApiResult } from '../api/ApiResult';

let generatedPartner: PartnerMatchType | null = null;

interface CandidateMatchEntry {
  candidate: UserProfile;
  match: PartnerMatchType;
}
let otherCandidateMatches: CandidateMatchEntry[] = [];

@Entry
@Component
struct PartnerMatch {
  @State invitationSent: boolean = false;
  /**
   * 联机模式下是否正在向后端请求匹配结果。
   *
   * 历史：本页原先用 `realModeUnavailable = !useFixture` 在联机时**直接不展示结果**，
   * 提示「当前后端尚未提供学习搭子匹配接口」。当时前端确实没接这个接口，
   * 那段提示是诚实的。但后端 `POST /api/v1/agent/partner-match` 早已实现，
   * 所以现在改为**联机时真的去请求后端**，由后端做确定性五因子算分。
   */
  @State partnerLoading: boolean = false;
  /** 联机匹配失败时的可读原因（失败不伪装成结果）。 */
  @State partnerError: string = '';
  /**
   * 联机模式下的匹配结果。
   *
   * ⚠️ 不写进 `generatedPartner`（那个是 `PartnerMatch` 视图模型，由本地
   * `LocalAgentService` 生成）。联机结果来自后端五因子算分，字段结构与本地
   * 计算不同（例如本地的 `score` 是百分比、后端是满分 100 的分值），
   * 混用会让人误以为是同一套算法。所以单独存一份并单独渲染。
   */
  @State onlineBest: PartnerRankedCandidate | null = null;
  @State onlineOthers: PartnerRankedCandidate[] = [];
  /**
   * **收到的**搭子邀请（只含待处理的）。
   *
   * 用户实测反馈原话：「我想知道如果被邀请的用户能否接受到，并且以怎样的途径同意…
   * 我的建议是如果有外来邀请消息可以在我的-搭子与协同页面上方弹出一个接受和
   * 不接受的选项，并且这个消息可以叉掉代表无视」——本页上方那块横幅就是它。
   *
   * 在此之前，后端**没有任何邀请实体**，本页那个「发起邀请」按钮也不调接口，
   * 只往本机周计划里插一条任务 —— 所谓邀请从来没有离开过发起人的手机。
   */
  @State incomingInvitations: PartnerInvitation[] = [];
  /** 接受之后真正"联系起来"的搭子名（服务端双向登记）。 */
  @State contactNames: string[] = [];
  /** 正在处理的邀请 id（同时用来禁用按钮，避免连点重复处理）。 */
  @State inviteBusy: string = '';
  @State inviteError: string = '';
  private collaborativeTaskId: string = '';
  /** 本页是否还在栈上（见 `onPageHide`）。 */
  private pageActive: boolean = true;

  aboutToAppear(): void {
    if (AgentApiClient.getConfig().useFixture) {
      this.loadLocalFixtureMatch();
    } else {
      this.loadOnlineMatch();
      // 收件箱与匹配结果互不依赖，但都必须在进页面时拉一次 ——
      // 邀请是**别人**发起的状态变化，不主动拉就永远看不到。
      this.loadInvitations();
      this.loadContacts();
    }
  }

  /**
   * 联机模式：向后端请求确定性五因子算分。
   *
   * 为什么要传 `user`：后端在没传时会用 `mock_users.json` 的 u001（小明），
   * 这在演示时正是我们想要的基线；但登录了真实账号时应以当前账号为准，
   * 所以这里把 `appState.currentUser` 传过去。
   *
   * 失败处理：**如实显示错误，不退回本地规则**。若退回本地算分，
   * 页面会显示一个"看起来是联机结果"的数字，但那其实是本地规则算的 ——
   * 正是本页原先要避免的"把本地结果伪装成在线 Agent 结果"。
   */
  private async loadOnlineMatch(): Promise<void> {
    this.partnerLoading = true;
    this.partnerError = '';
    this.onlineBest = null;
    this.onlineOthers = [];
    try {
      const result = await AgentApiClient.matchPartner({
        userId: appState.currentUser?.userId,
        user: appState.currentUser as PartnerCandidateProfile
      });
      // ⚠️ ArkTS 的类型收窄不认 `if (!result.ok)` —— 即使写了显式 `else`，
      // 在 else 分支里访问 `result.error` 仍报
      // 「Property 'error' does not exist on type 'ApiResult<...>'」（实测编译失败）。
      // 既有代码（`AuthClient.describe`）也是用**辅助函数**绕开这一点，这里保持一致。
      if (result.ok) {
        const payload: PartnerMatchResponse = result.data;
        this.onlineBest = payload.matchedCandidate;
        const others: PartnerRankedCandidate[] = [];
        for (let index: number = 0; index < payload.candidates.length; index++) {
          const item: PartnerRankedCandidate = payload.candidates[index];
          if (this.onlineBest === null || item.candidate.userId !== this.onlineBest!.candidate.userId) {
            others.push(item);
          }
        }
        this.onlineOthers = others;
      } else {
        this.partnerError = PartnerMatch.describeFailure<PartnerMatchResponse>(result);
      }
    } catch (error) {
      this.partnerError = '匹配请求失败，请检查后端服务是否已启动。';
    } finally {
      this.partnerLoading = false;
    }
  }

  /** 离线 Fixture：沿用原有的本地规则匹配（用于无后端演示）。 */
  private loadLocalFixtureMatch(): void {
    generatedPartner = LocalAgentService.matchBestPartner(appState.currentUser, appState.candidates);
    if (generatedPartner !== null && appState.latestPartner?.userId === generatedPartner.userId) {
      const previousTask: LearningPlanTask = LocalAgentService.createCollaborativeTask(generatedPartner, appState.currentUser);
      if (!appState.hasActiveCollaborativeTask(previousTask.id) &&
          appState.hasCompletedCollaborativeTask(previousTask.id)) {
        const remainingCandidates: UserProfile[] = appState.candidates.filter((candidate: UserProfile) =>
          candidate.userId !== generatedPartner!.userId
        );
        generatedPartner = LocalAgentService.matchBestPartner(appState.currentUser, remainingCandidates);
      }
    }
    otherCandidateMatches = [];
    for (let index: number = 0; index < appState.candidates.length; index++) {
      const candidate: UserProfile = appState.candidates[index];
      if (generatedPartner === null || candidate.userId !== generatedPartner!.userId) {
        otherCandidateMatches.push({
          candidate: candidate,
          match: LocalAgentService.matchPartner(appState.currentUser, candidate)
        });
      }
    }
    if (generatedPartner !== null) {
      const task: LearningPlanTask = LocalAgentService.createCollaborativeTask(generatedPartner, appState.currentUser);
      this.collaborativeTaskId = appState.nextCollaborativeTaskId(task.id);
      this.invitationSent = appState.latestPartner?.userId === generatedPartner.userId &&
        appState.hasActiveCollaborativeTask(task.id);
    }
  }

  private goBack(): void {
    appState.leaveChatTask();
    router.back();
  }

  /**
   * 把后端的真实匹配结果转成本地协同任务流程认识的 `PartnerMatch`。
   *
   * 为什么需要：离线分支用 `LocalAgentService` 本地算分、直接产出 `PartnerMatch`；
   * 在线分支拿到的是后端算好的 `PartnerRankedCandidate`（含五因子拆解）。
   * 原先在线分支**根本走不到"发起邀请"**，只能浏览 —— 用户反馈的
   * "联机模式流程走不完"就是这个。
   *
   * ⚠️ 因子与得分**全部来自后端**（`onlineBest.factors` / `.score`），
   * 这里只做结构转换，不重新算分、不编数字。
   */
  private onlineAsPartner(): PartnerMatchType | null {
    if (this.onlineBest === null) {
      return null;
    }
    const candidate: PartnerCandidateProfile = this.onlineBest.candidate;
    const factors: PartnerMatchFactors = this.onlineBest.factors;
    const rows: MatchFactor[] = [
      { label: '学习目标匹配', score: `${factors.goal}`, match: factors.goal > 0, detail: '后端五因子算分' },
      { label: '空闲时间重叠', score: `${factors.timeOverlap}`, match: factors.timeOverlap > 0,
        detail: `重叠 ${factors.overlapMinutes} 分钟` },
      { label: '知识互补', score: `${factors.knowledgeComplement}`, match: factors.knowledgeComplement > 0,
        detail: '强项与弱项互补程度' },
      { label: '基础信息相近', score: `${factors.basicMatch}`, match: factors.basicMatch > 0,
        detail: '年级与专业相近度' },
      { label: '学习稳定性', score: `${factors.stability}`, match: factors.stability > 0,
        detail: '近期学习活跃度' }
    ];
    const info: PartnerCandidateBasicInfo | undefined = candidate.basicInfo;
    const displayName: string = info !== undefined && info.name !== undefined && info.name.length > 0
      ? info.name : '学习搭子';
    return {
      matchName: displayName,
      userId: candidate.userId,
      score: this.onlineBest.score,
      reasons: [`后端综合匹配分 ${this.onlineBest.score}`],
      studyTime: null,
      duration: factors.overlapMinutes,
      matchFactors: rows
    };
  }

  /**
   * 在线（真实后端）匹配结果的「发起学习邀请」。
   *
   * ⚠️ 与离线分支的关键差别：**必须先真的把邀请发到服务端**。
   * 原实现两个分支都只调 `confirmPartnerWith`（写本机周计划），
   * 于是"邀请"从来没有离开过发起人的手机 —— 用户实测反馈问的
   * 「被邀请的用户能否接受到」，那时的答案是不能。
   * 服务端失败时**如实报错并且不往下走**：本地协同任务照做毫无意义，
   * 对方根本收不到，那正是本工程禁止的"静默假成功"。
   */
  private async confirmOnlinePartner(): Promise<void> {
    const partner: PartnerMatchType | null = this.onlineAsPartner();
    if (partner === null || this.onlineBest === null) {
      return;
    }
    const targetId: string = this.onlineBest.candidate.userId;
    const targetName: string = partner.matchName;
    // 后端如实标注对方是真实账号还是演示同学（见 ApiModels 的 PartnerInvitation 注释）。
    const isDemoTarget: boolean = this.onlineBest.candidate.accountKind !== 'account';

    this.inviteError = '';
    this.inviteBusy = targetId;
    const result: ApiResult<PartnerInvitationResponse> =
      await AgentApiClient.createPartnerInvitation({
        toUserId: targetId,
        message: '一起学数据结构吧'
      });
    this.inviteBusy = '';

    if (!result.ok) {
      this.inviteError = `邀请没有发出去：${PartnerMatch.describeFailure<PartnerInvitationResponse>(result)}`;
      return;
    }
    // 邀请真实送达 / 记为演示对象 —— 两种情况的说法**必须不同**，
    // 不能让用户以为小红（演示同学，没有账号）会给他回消息。
    const notice: string = isDemoTarget
      ? `已记录向 ${targetName} 的邀请。注意：${targetName} 是演示同学（没有真实账号），不会真的回复。`
      : `已向 ${targetName} 发出学习邀请。对方登录后会在「搭子与协同」页看到，并可选择接受或拒绝。`;
    this.confirmPartnerWith(partner, notice);
  }

  /** 收件箱：只含**待处理**的邀请（处理过的由后端过滤掉）。 */
  private async loadInvitations(): Promise<void> {
    const result = await AgentApiClient.listPartnerInvitations('inbox');
    if (!this.pageActive) {
      return;
    }
    if (result.ok) {
      this.incomingInvitations = result.data.invitations;
      return;
    }
    // 拉不到收件箱不该把整页变成错误页，但也不能假装"没有邀请" —— 如实说一句。
    this.inviteError = `暂时读不到邀请收件箱：${PartnerMatch.describeFailure<PartnerInvitationListResponse>(result)}`;
  }

  /** 接受之后真正"联系起来"的那份名单。 */
  private async loadContacts(): Promise<void> {
    const result = await AgentApiClient.listPartnerContacts();
    if (result.ok) {
      this.contactNames = result.data.contacts.map((item: PartnerContact) => item.partnerName);
    }
  }

  /**
   * 处理一条收到的邀请。
   *
   * 三个动作语义**刻意分开**，对应用户反馈里说的"接受/不接受"与"叉掉代表无视"：
   *   accept  → 后端把双方互相登记为搭子（`contacts`），这才是"两个人联系起来"
   *   decline → 明确回复对方不接受
   *   dismiss → 只是自己不想再看到（无视），与"不接受"分开记状态
   */
  private async respondInvitation(item: PartnerInvitation, action: string): Promise<void> {
    if (this.inviteBusy.length > 0) {
      return;
    }
    this.inviteBusy = item.invitationId;
    this.inviteError = '';
    let result: ApiResult<PartnerInvitationResponse>;
    if (action === 'accept') {
      result = await AgentApiClient.acceptPartnerInvitation(item.invitationId);
    } else if (action === 'decline') {
      result = await AgentApiClient.declinePartnerInvitation(item.invitationId);
    } else {
      result = await AgentApiClient.dismissPartnerInvitation(item.invitationId);
    }
    this.inviteBusy = '';
    if (!result.ok) {
      this.inviteError = `处理失败：${PartnerMatch.describeFailure<PartnerInvitationResponse>(result)}`;
      return;
    }
    // 重新拉一次，让界面与**服务端事实**一致 —— 而不是本地先删掉再等下次对账。
    await this.loadInvitations();
    if (action === 'accept') {
      await this.loadContacts();
    }
  }

  onPageShow(): void {
    this.pageActive = true;
  }

  /**
   * 离开页面时置位。
   *
   * 邀请是**异步**拉取的，用户完全可能在响应回来之前就退出本页 ——
   * 那时再写 @State 没有意义，还会让下次进页面时闪一下过期数据。
   */
  onPageHide(): void {
    this.pageActive = false;
  }

  private confirmPartner(): void {
    if (generatedPartner === null) {
      return;
    }
    this.confirmPartnerWith(generatedPartner);
  }

  /**
   * 共用的协同任务落地流程（离线/在线两个入口都走这里，行为一致）。
   *
   * `serverNotice` 非空时**覆盖**默认那句"已发出邀请"—— 联机分支用它如实区分
   * "对方是真实账号（登录后会看到）"与"对方是演示同学（不会真的回复）"，
   * 不能让两种情况共用一句"已发出邀请"。
   */
  private confirmPartnerWith(partner: PartnerMatchType, serverNotice: string = ''): void {
    if (appState.weeklyPlan === null) {
      appState.setWeeklyPlan(LocalAgentService.generateWeeklyPlan(
        appState.courses, appState.homeworkDDLs, appState.currentUser
      ));
    }
    const collaborativeTask: LearningPlanTask = LocalAgentService.createCollaborativeTask(partner, appState.currentUser);
    collaborativeTask.id = this.collaborativeTaskId.length > 0 ? this.collaborativeTaskId :
      appState.nextCollaborativeTaskId(collaborativeTask.id);
    const added: boolean = appState.addCollaborativeTask(
      collaborativeTask,
      `已安排与${partner.matchName}的协同学习任务。`
    );
    appState.latestPartner = partner;
    this.invitationSent = true;
    const name: string = partner.matchName;
    appState.completeChatTask(
      serverNotice.length > 0
        ? serverNotice
        : (added ? `已向 ${name} 发出学习邀请，并加入协同学习任务。`
                 : `与 ${name} 的协同学习任务已经在计划中。`),
      '接下来可以确认协同任务并开始专注。',
      '查看本周计划',
      'pages/StudyPlan'
    );
    ChatNavigation.returnToChat();
  }

  /**
   * 收到的邀请横幅 —— 放在页面**最上方**（用户反馈里明确要求的位置）。
   *
   * 三条操作刻意分开：接受 / 不接受 / ✕（无视）。✕ 与"不接受"不是一回事：
   * 前者只是自己不想再看到，后者是明确回复对方；后端也分开记状态
   * （`dismissed` vs `declined`），以后要接消息通知时不用改数据模型。
   */
  @Builder
  InvitationBanner() {
    Column({ space: 12 }) {
      ForEach(this.incomingInvitations, (item: PartnerInvitation) => {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Text('🤝').fontSize(18)
            Text(`${item.fromName} 想和你组成学习搭子`).fontSize(15)
              .fontWeight(FontWeight.Bold).fontColor('#172033').layoutWeight(1)
            // 叉掉 = 无视。放在右上角，符合用户对"消息可叉掉"的预期。
            Text('✕').fontSize(16).fontColor('#94A3B8')
              .onClick(() => { void this.respondInvitation(item, 'dismiss'); })
          }.width('100%')

          if (item.message.length > 0) {
            Text(item.message).fontSize(13).fontColor('#5F7485').lineHeight(19).width('100%')
          }
          if (item.targetKind === 'demo') {
            Text('（这是一位演示同学，没有真实账号）')
              .fontSize(11).fontColor('#B45309').width('100%')
          }

          Row({ space: 10 }) {
            Button(this.inviteBusy === item.invitationId ? '处理中…' : '接受')
              .layoutWeight(1).height(40).fontSize(14).fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(10)
              .enabled(this.inviteBusy.length === 0)
              .onClick(() => { void this.respondInvitation(item, 'accept'); })
            Button('不接受')
              .layoutWeight(1).height(40).fontSize(14).fontColor('#2563EB')
              .backgroundColor('#EFF6FF').borderRadius(10)
              .enabled(this.inviteBusy.length === 0)
              .onClick(() => { void this.respondInvitation(item, 'decline'); })
          }.width('100%')
        }
        .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
        .border({ width: 1, color: '#BFDBFE' })
      }, (item: PartnerInvitation) => item.invitationId)
    }.width('100%')
  }

  @Builder
  MatchScoreBoard() {
    Column({ space: 4 }) {
      Text('匹配因子分析').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#172033').width('100%').margin({ bottom: 6 })

      if (generatedPartner !== null && generatedPartner.matchFactors.length > 0) {
        ForEach(generatedPartner.matchFactors, (factor: MatchFactor, index: number) => {
          Row() {
            Column() {
              Text((index + 1).toString()).fontSize(14).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
                .textAlign(TextAlign.Center).width(26).height(26).borderRadius(13)
                .backgroundColor(factor.match ? '#2563EB' : '#C4CDD5')
            }.margin({ right: 12 })

            Column({ space: 2 }) {
              Text(factor.label).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#172033')
              Text(factor.detail).fontSize(12).fontColor('#667085')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)

            Text(factor.score).fontSize(18).fontWeight(FontWeight.Bold)
              .fontColor(factor.match ? '#2563EB' : '#C4CDD5')
          }
          .width('100%').padding({ top: 12, bottom: 12 })
          .border({ width: { bottom: index < generatedPartner!.matchFactors.length - 1 ? 0.5 : 0 }, color: '#E0E7EF' })
        }, (factor: MatchFactor) => factor.label)

        Divider().color('#E0E7EF').margin({ top: 4, bottom: 4 })

        Row() {
          Text('综合匹配度').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#172033')
Text(`${generatedPartner.score}%`).fontSize(28).fontWeight(FontWeight.Bold).fontColor('#2563EB')
        }.width('100%').padding({ top: 8, bottom: 4 })
      } else {
        Text('暂无满足条件的候选搭子。请先补充课程、目标和空闲时间，再重新进入本页。')
          .fontSize(13).fontColor('#667085').lineHeight(20).width('100%').padding({ top: 8, bottom: 8 })
      }
    }
    .width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
    .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 6 })
  }

  /* ================================================================
   * 联机模式（后端确定性五因子算分）的渲染
   *
   * 与离线 Fixture 的 `MatchScoreBoard()` 分开写，是刻意的：
   * 后端因子是**分值**（goal 30 / timeOverlap 30 / knowledgeComplement 20
   * / basicMatch 10 / stability 10），本地因子是**百分比**。
   * 合在一起渲染会让人误以为是同一套算法。
   * ================================================================ */

  /**
   * 从失败的 ApiResult 里取出可读文案。
   *
   * ⚠️ 为什么要单独抽方法 + 显式 `as ApiFailure`：
   * ArkTS **不做** `ApiResult<T>` 的联合类型收窄 ——
   * 无论写 `if (!result.ok)` 还是 `if (result.ok) {...} else { result.error }`，
   * 访问 `.error` 都会编译失败：
   *     Property 'error' does not exist on type 'ApiResult<...>'
   * 既有代码 `AuthClient.describe()` 用的就是这个 cast 写法，这里保持一致。
   */
  /**
   * 把失败结果翻译成一句人话。
   *
   * ⚠️ 参数写成**泛型**而不是 `ApiResult<PartnerMatchResponse>`：本页现在还要处理
   * 邀请的四个接口（发起 / 收件箱 / 接受 / 拒绝 / 无视），它们的响应类型不同，
   * 写死成匹配响应会让 `describeFailure(邀请结果)` 直接编译不过
   * （实测报 "Argument of type 'ApiResult<PartnerInvitationResponse>' is not
   * assignable to parameter of type 'ApiResult<PartnerMatchResponse>'"）。
   * 这个方法只读 `error` 字段，与业务数据类型无关，本来就不该被绑死。
   */
  private static describeFailure<T>(result: ApiResult<T>): string {
    const failure = result as ApiFailure;
    if (failure.error.code === 'NETWORK_ERROR') {
      return '连接不上后端服务。请确认后端已启动，并在「接口环境」里填对了地址。';
    }
    return failure.error.message;
  }

  /** 单个因子的展示文案：名称 / 得分 / 满分 / 说明。 */
  private factorRows(item: PartnerRankedCandidate): MatchFactor[] {
    const f: PartnerMatchFactors = item.factors;
    return [
      {
        label: '目标一致', score: `${f.goal} / 30`, match: f.goal >= 30,
        detail: f.goal >= 30 ? '课程与目标完全相同' : (f.goal > 0 ? '课程相同、具体目标不同' : '目标不一致')
      },
      {
        label: '时间重叠', score: `${f.timeOverlap} / 30`, match: f.timeOverlap >= 30,
        detail: `空闲时间重叠 ${f.overlapMinutes} 分钟（≥120 得满分）`
      },
      {
        label: '知识互补', score: `${f.knowledgeComplement} / 20`, match: f.knowledgeComplement >= 20,
        detail: '你弱我强 / 我弱你强的知识点对数（≥2 对得满分）'
      },
      {
        label: '基础匹配', score: `${f.basicMatch} / 10`, match: f.basicMatch >= 10,
        detail: '年级与专业是否一致'
      },
      {
        label: '稳定性', score: `${f.stability} / 10`, match: f.stability >= 10,
        detail: '候选人的空闲时间段是否稳定'
      }
    ];
  }

  private candidateName(item: PartnerRankedCandidate): string {
    return item.candidate.basicInfo?.name ?? item.candidate.userId;
  }

  private candidateSubtitle(item: PartnerRankedCandidate): string {
    const basic = item.candidate.basicInfo;
    const goal = item.candidate.learningGoal;
    const parts: string[] = [];
    if (basic?.grade) { parts.push(basic.grade); }
    if (basic?.major) { parts.push(basic.major); }
    if (goal?.course) { parts.push(goal.course); }
    return parts.join(' · ');
  }

  @Builder
  OnlineBestCard(item: PartnerRankedCandidate) {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 4 }) {
          Text(`🏅 ${this.candidateName(item)}`)
            .fontSize(22).fontWeight(FontWeight.Bold).fontColor('#172033')
          Text('最佳学习伙伴').fontSize(13).fontColor('#2563EB').fontWeight(FontWeight.Medium)
          Text(this.candidateSubtitle(item)).fontSize(12).fontColor('#667085')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column() {
          Text(`${item.score}`).fontSize(30).fontWeight(FontWeight.Bold).fontColor('#2563EB')
          Text('匹配分 / 100').fontSize(11).fontColor('#667085')
        }.alignItems(HorizontalAlign.Center)
      }.width('100%')

      if (item.candidate.time?.freeTime !== undefined && item.candidate.time?.freeTime?.length > 0) {
        Text(`空闲时间：${item.candidate.time?.freeTime?.join('、')}`)
          .fontSize(13).fontColor('#667085')
      }
      Text('分数由后端确定性算法给出：同一份资料每次结果完全一致，可复核。')
        .fontSize(12).fontColor('#0F766E').lineHeight(19)
    }
    .width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
    .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 6 })
  }

  @Builder
  OnlineFactorBoard(item: PartnerRankedCandidate) {
    Column({ space: 10 }) {
      Text('匹配因子分析').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#172033')
        .width('100%')

      ForEach(this.factorRows(item), (factor: MatchFactor) => {
        Row() {
          Column({ space: 2 }) {
            Text(factor.label).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#1F2937')
            Text(factor.detail).fontSize(11).fontColor('#667085').lineHeight(17)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)

          Text(factor.score)
            .fontSize(14).fontWeight(FontWeight.Bold)
            .fontColor(factor.match ? '#0F766E' : '#B45309')
        }
        .width('100%').padding(12)
        .backgroundColor(factor.match ? '#F0FDFA' : '#FFFBEB').borderRadius(10)
      }, (factor: MatchFactor) => factor.label)

      Text('五项相加即为总分（满分 100）。')
        .fontSize(11).fontColor('#94A3B8').width('100%')
    }
    .width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
    .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 6 })
  }

  @Builder
  OnlineOtherRow(item: PartnerRankedCandidate) {
    Row() {
      Column({ space: 2 }) {
        Text(this.candidateName(item)).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#172033')
        Text(this.candidateSubtitle(item)).fontSize(12).fontColor('#667085')
        Text(`时间重叠 ${item.factors.overlapMinutes} 分钟 · 知识互补 ${item.factors.knowledgeComplement} 分`)
          .fontSize(11).fontColor('#94A3B8')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Column() {
        Text(`${item.score}`).fontSize(20).fontWeight(FontWeight.Bold).fontColor('#2563EB')
        Text('匹配分').fontSize(10).fontColor('#667085')
      }.alignItems(HorizontalAlign.Center)
    }
    .width('100%').padding(14).backgroundColor('#FFFFFF').borderRadius(12)
    .shadow({ radius: 8, color: '#0F000000', offsetX: 0, offsetY: 3 })
  }

  build() {
    Stack() {
    Column() {
      Row() {
        Text('← 返回').fontSize(14).fontColor('#64748B').fontWeight(FontWeight.Medium)
          .onClick(() => { this.goBack(); })
        Blank()
        Text('找学习搭子').fontSize(13).fontColor('#2563EB').fontWeight(FontWeight.Bold)
          .backgroundColor('#EFF6FF').borderRadius(16).padding({ left: 12, right: 12, top: 6, bottom: 6 })
      }
      .width('100%').padding({ left: 20, right: 20, top: 12, bottom: 12 })
      .backgroundColor('#FFFFFF').shadow({ radius: 4, color: '#08000000', offsetX: 0, offsetY: 2 })

      Scroll() {
        Column({ space: 18 }) {
          Text('找学习搭子')
            .fontSize(26).fontWeight(FontWeight.Bold).fontColor('#172033').width('100%')

          Text('基于课程、目标、知识结构、空闲时间智能匹配最佳学习伙伴')
            .fontSize(14).fontColor('#667085').lineHeight(21).width('100%')

          if (!AgentApiClient.getConfig().useFixture) {
            /* ============ 联机模式：后端确定性五因子算分 ============ */
            Row({ space: 6 }) {
              Text('🧮').fontSize(12)
              Text('匹配由后端确定性算法完成（五因子，满分 100）')
                .fontSize(11).fontColor('#0F766E')
            }.width('100%').padding(8).backgroundColor('#F0FDFA').borderRadius(8)

            Text('仅共享课程与学习标签，不展示个人联系方式。')
              .fontSize(12).fontColor('#5F7485').width('100%').padding(12)
              .backgroundColor('#EFF6FF').borderRadius(12)

            // ★ 收到别人的邀请时，在**页面最上方**给出接受 / 不接受 / ✕（无视）。
            // 位置与方法名都照用户实测反馈的要求来："如果有外来邀请消息可以在
            // 我的-搭子与协同页面上方弹出一个接受和不接受的选项，并且这个消息
            // 可以叉掉代表无视"。
            if (this.incomingInvitations.length > 0) {
              this.InvitationBanner()
            }
            // 邀请相关的问题**独立展示**，不并进上面的"匹配未能完成"错误卡 ——
            // 匹配成功但收件箱拉不到，是两件事，混在一起会误导排查方向。
            if (this.inviteError.length > 0) {
              Text(this.inviteError).fontSize(12).fontColor('#B91C1C').lineHeight(18)
                .width('100%').padding(12).backgroundColor('#FEF2F2')
                .border({ width: 1, color: '#FECACA' }).borderRadius(10)
            }
            if (this.contactNames.length > 0) {
              Text(`已建立学习搭子：${this.contactNames.join('、')}`)
                .fontSize(12).fontColor('#0F766E').width('100%').padding(12)
                .backgroundColor('#ECFDF5').borderRadius(10)
            }

            if (this.partnerLoading) {
              Column({ space: 10 }) {
                LoadingProgress().width(40).height(40).color('#2563EB')
                Text('正在计算匹配度…').fontSize(14).fontColor('#667085')
              }
              .width('100%').padding(28).backgroundColor('#FFFFFF').borderRadius(18)
            } else if (this.partnerError.length > 0) {
              Column({ space: 10 }) {
                Text('匹配未能完成').fontSize(17).fontWeight(FontWeight.Bold)
                  .fontColor('#B91C1C').width('100%')
                Text(this.partnerError).fontSize(13).fontColor('#7F1D1D')
                  .lineHeight(20).width('100%')
                Text('为避免把本地规则结果伪装成在线 Agent 结果，这里如实显示失败原因，而不是退回本地算分。')
                  .fontSize(12).fontColor('#991B1B').lineHeight(19).width('100%')
                Button('重试')
                  .width('100%').height(44).fontSize(14).fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF').backgroundColor('#DC2626').borderRadius(12)
                  .onClick(() => { this.loadOnlineMatch(); })
                Button('前往环境设置')
                  .width('100%').height(42).fontSize(14).fontColor('#991B1B')
                  .backgroundColor('#FEF2F2').border({ width: 1, color: '#FCA5A5' })
                  .borderRadius(12)
                  .onClick(() => router.pushUrl({ url: 'pages/ApiEnvironment' }))
              }
              .width('100%').padding(18).backgroundColor('#FEF2F2').borderRadius(16)
              .border({ width: 1, color: '#FECACA' })
            } else if (this.onlineBest !== null) {
              /* 最佳匹配 */
              this.OnlineBestCard(this.onlineBest)

              /* 五因子拆解：让人看懂 90 分是怎么来的 */
              this.OnlineFactorBoard(this.onlineBest)

              /* 其他候选人 */
              if (this.onlineOthers.length > 0) {
                Column({ space: 8 }) {
                  Text('👥 其他候选人').fontSize(16).fontWeight(FontWeight.Bold)
                    .fontColor('#172033').width('100%').margin({ bottom: 4 })
                  ForEach(this.onlineOthers, (item: PartnerRankedCandidate) => {
                    this.OnlineOtherRow(item)
                  }, (item: PartnerRankedCandidate) => item.candidate.userId)
                }.width('100%')
              }

              // ⚠️ 在线分支**必须也有「发起邀请」**。
              // 原先这里到上面就结束了：联机（登录）用户能看到匹配结果与五因子拆解，
              // 却没有任何按钮可以往下走 —— 流程断在半路。
              // 现在与离线分支共用同一套协同任务流程（confirmPartnerWith）。
              Column({ space: 8 }) {
                Text('确认后将回到对话，由知学Mate继续安排共同学习。')
                  .fontSize(12).fontColor('#667085').lineHeight(18).width('100%')
                Button(this.inviteBusy === this.onlineBest.candidate.userId
                  ? '正在发送邀请…' : (this.invitationSent ? '查看协同任务' : '向该搭子发起学习邀请'))
                  .width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                  .backgroundColor('#2563EB').borderRadius(14)
                  .enabled(this.inviteBusy.length === 0)
                  .onClick(() => {
                    if (this.invitationSent) {
                      router.pushUrl({ url: 'pages/StudyPlan' });
                    } else {
                      // 这条路径现在是**真的**发一个服务端邀请（见 confirmOnlinePartner）：
                      // 失败会如实报错并停在这里，不再"本机假装已发出"。
                      void this.confirmOnlinePartner();
                    }
                  })
              }
              .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
            } else {
              Column({ space: 8 }) {
                Text('暂无可匹配的候选人').fontSize(17).fontWeight(FontWeight.Bold)
                  .fontColor('#172033').width('100%')
                Text('后端已返回结果，但所有候选人的匹配分都为 0。')
                  .fontSize(13).fontColor('#667085').lineHeight(20).width('100%')
              }
              .width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
            }
          } else {
            /* ============ 离线 Fixture：本地规则匹配（无后端演示） ============ */
            Text(appState.getChatTaskContext()).fontSize(12).fontColor('#2563EB')
            .width('100%').padding(10).backgroundColor('#EFF6FF').borderRadius(10)

          // Agent数据来源标识
          Row({ space: 6 }) {
            Text('🤖').fontSize(12)
            Text(`Agent基于${appState.isDataImported ? '导入数据' : '演示数据'}进行匹配分析`)
              .fontSize(11).fontColor('#667085')
Text(`${appState.candidates.length}位候选`).fontSize(11).fontColor('#2563EB')
              .backgroundColor('#EFF6FF').borderRadius(8).padding({ left: 8, right: 8, top: 2, bottom: 2 })
          }.width('100%').padding(8).backgroundColor('#EFF6FF').borderRadius(8)

          Text('仅共享课程与学习标签，不展示个人联系方式。')
            .fontSize(12).fontColor('#5F7485').width('100%').padding(12).backgroundColor('#EFF6FF').borderRadius(12)

          /* 最佳匹配 */
          if (generatedPartner !== null) {
            Column({ space: 10 }) {
              Row() {
                Column({ space: 4 }) {
                  Text(`🏅 ${generatedPartner.matchName}`).fontSize(22).fontWeight(FontWeight.Bold).fontColor('#172033')
                  Text('最佳学习伙伴').fontSize(13).fontColor('#2563EB').fontWeight(FontWeight.Medium)
                }
Column() {
                  Text(`${generatedPartner.score}%`).fontSize(30).fontWeight(FontWeight.Bold).fontColor('#2563EB')
                  Text('匹配度').fontSize(11).fontColor('#667085')
                }.alignItems(HorizontalAlign.Center)
              }.width('100%')

              if (generatedPartner.studyTime !== null) {
                Text(`建议学习时间：${generatedPartner.studyTime} · 时长 ${generatedPartner.duration} 分钟`)
                  .fontSize(13).fontColor('#667085')
              }
              Text(`"${generatedPartner.reasons.join('、')}"`)
                .fontSize(14).fontColor('#344054').lineHeight(21)
            }
            .width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
            .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 6 })
          }

          /* 匹配因子分析 */
          this.MatchScoreBoard()

          /* 其他候选人 */
          if (otherCandidateMatches.length > 0) {
            Column({ space: 4 }) {
              Text('👥 其他候选人').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#172033')
                .width('100%').margin({ bottom: 4 })

              ForEach(otherCandidateMatches, (entry: CandidateMatchEntry) => {
                Row() {
                  Column({ space: 2 }) {
                    Text(entry.candidate.basicInfo.name).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#172033')
                    Text(`${entry.candidate.basicInfo.grade} · ${entry.candidate.basicInfo.major}`)
                      .fontSize(12).fontColor('#667085')
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)

                  Column() {
                    Text(`${entry.match.score}%`).fontSize(20).fontWeight(FontWeight.Bold).fontColor('#2563EB')
                    Text('匹配度').fontSize(10).fontColor('#667085')
                  }.alignItems(HorizontalAlign.Center)
                }
                .width('100%').padding(14).backgroundColor('#FFFFFF').borderRadius(14)
                .shadow({ radius: 4, color: '#0C000000', offsetX: 0, offsetY: 2 })
              }, (entry: CandidateMatchEntry) => entry.candidate.userId)
            }.width('100%')
          }

          // 合作学习可视化看板
          if (generatedPartner !== null) {
            Column({ space: 12 }) {
              Text('🤝 合作学习看板')
                .fontSize(17).fontWeight(FontWeight.Bold).fontColor('#111827').width('100%')

              Row({ space: 12 }) {
                Column({ space: 6 }) {
                  Text('你擅长').fontSize(11).fontColor('#6B7280')
                  Text(appState.currentUser.knowledge.strength.slice(0, 3).join('、') || '暂无')
                    .fontSize(13).fontWeight(FontWeight.Medium).fontColor('#2563EB').maxLines(2)
                }.width('45%').padding(10).backgroundColor('#EFF6FF').borderRadius(10)

                Column({ space: 6 }) {
                  Text('对方擅长').fontSize(11).fontColor('#6B7280')
                  Text(generatedPartner.matchName).fontSize(13).fontWeight(FontWeight.Medium).fontColor('#3B82F6')
                }.width('45%').padding(10).backgroundColor('#EFF6FF').borderRadius(10)
              }.width('100%')

              Row({ space: 8 }) {
                Column({ space: 4 }) {
                  Text('①').fontSize(18).fontColor('#2563EB')
                  Text('互讲概念').fontSize(10).fontColor('#6B7280')
                }.width('30%').padding(8).backgroundColor('#EFF6FF').borderRadius(8)
                Text('→').fontSize(16).fontColor('#9CA3AF')
                Column({ space: 4 }) {
                  Text('②').fontSize(18).fontColor('#2563EB')
                  Text('互测练习').fontSize(10).fontColor('#6B7280')
                }.width('30%').padding(8).backgroundColor('#EFF6FF').borderRadius(8)
                Text('→').fontSize(16).fontColor('#9CA3AF')
                Column({ space: 4 }) {
                  Text('③').fontSize(18).fontColor('#2563EB')
                  Text('错题复盘').fontSize(10).fontColor('#6B7280')
                }.width('30%').padding(8).backgroundColor('#EFF6FF').borderRadius(8)
              }.width('100%').justifyContent(FlexAlign.Center)

              Text('协同时间：' + (generatedPartner.studyTime || '20:00-21:00') + ' · 共' + (generatedPartner.duration || 60) + '分钟')
                .fontSize(12).fontColor('#6B7280')
            }
            .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
            .shadow({ radius: 8, color: '#10000000', offsetX: 0, offsetY: 3 })
          }

          Column({ space: 8 }) {
            Text('确认后将回到对话，由知学Mate继续安排共同学习。')
              .fontSize(12).fontColor('#667085').lineHeight(18).width('100%')
            Button(this.invitationSent ? '查看协同任务' : '向该搭子发起学习邀请')
              .width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
              .backgroundColor('#2563EB').borderRadius(14).enabled(generatedPartner !== null)
              .onClick(() => {
                if (this.invitationSent) {
                  router.pushUrl({ url: 'pages/StudyPlan' });
                } else {
                  this.confirmPartner();
                }
              })
            if (!appState.isDataImported) {
              Text('资料不足时，可在对话里补充课程和空闲时间。')
                .fontSize(12).fontColor('#667085').width('100%').textAlign(TextAlign.Center)
            }
          }
          .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
          .shadow({ radius: 8, color: '#10000000', offsetX: 0, offsetY: 3 })
          }
        }
        .width('100%').padding({ left: 20, right: 20, top: 16, bottom: 40 })
      }
      .layoutWeight(1)
    }
    .width('100%').height('100%').backgroundColor('#EFF6FF')
    AIFloatButton()
    }.width('100%').height('100%')
  }
}
