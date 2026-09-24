import router from '@ohos.router';
import { appState } from '../data/AppState';
import { PartnerMatch as PartnerMatchType, MatchFactor, UserProfile, LearningPlanTask } from '../models/AgentModels';
import { LocalAgentService } from '../services/LocalAgentService';
import { ChatNavigation } from '../services/ChatNavigation';
import { AIFloatButton } from '../components/AIFloatButton';
import { AgentApiClient } from '../api/AgentApiClient';
import {
  PartnerCandidateProfile,
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
  private collaborativeTaskId: string = '';

  aboutToAppear(): void {
    if (AgentApiClient.getConfig().useFixture) {
      this.loadLocalFixtureMatch();
    } else {
      this.loadOnlineMatch();
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
        this.partnerError = PartnerMatch.describeFailure(result);
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

  private confirmPartner(): void {
    if (generatedPartner === null) {
      return;
    }
    if (appState.weeklyPlan === null) {
      appState.setWeeklyPlan(LocalAgentService.generateWeeklyPlan(
        appState.courses, appState.homeworkDDLs, appState.currentUser
      ));
    }
    const collaborativeTask: LearningPlanTask = LocalAgentService.createCollaborativeTask(generatedPartner, appState.currentUser);
    collaborativeTask.id = this.collaborativeTaskId.length > 0 ? this.collaborativeTaskId :
      appState.nextCollaborativeTaskId(collaborativeTask.id);
    const added: boolean = appState.addCollaborativeTask(
      collaborativeTask,
      `已安排与${generatedPartner.matchName}的协同学习任务。`
    );
    appState.latestPartner = generatedPartner;
    this.invitationSent = true;
    const name: string = generatedPartner.matchName;
    appState.completeChatTask(
      added ? `已向 ${name} 发出学习邀请，并加入协同学习任务。` : `与 ${name} 的协同学习任务已经在计划中。`,
      '接下来可以确认协同任务并开始专注。',
      '查看本周计划',
      'pages/StudyPlan'
    );
    ChatNavigation.returnToChat();
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
  private static describeFailure(result: ApiResult<PartnerMatchResponse>): string {
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
