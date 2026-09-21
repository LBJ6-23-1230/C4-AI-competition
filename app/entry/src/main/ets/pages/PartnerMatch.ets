import router from '@ohos.router';
import { appState } from '../data/AppState';
import { PartnerMatch as PartnerMatchType, MatchFactor, UserProfile, LearningPlanTask } from '../models/AgentModels';
import { LocalAgentService } from '../services/LocalAgentService';
import { ChatNavigation } from '../services/ChatNavigation';
import { AIFloatButton } from '../components/AIFloatButton';
import { AgentApiClient } from '../api/AgentApiClient';

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
  @State realModeUnavailable: boolean = false;
  private collaborativeTaskId: string = '';

  aboutToAppear(): void {
    this.realModeUnavailable = !AgentApiClient.getConfig().useFixture;
    if (this.realModeUnavailable) {
      generatedPartner = null;
      otherCandidateMatches = [];
      return;
    }
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

          if (this.realModeUnavailable) {
            Column({ space: 12 }) {
              Text('联机模式暂不生成搭子结果')
                .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#92400E').width('100%')
              Text('当前后端尚未提供学习搭子匹配接口。为避免把本地规则结果伪装成在线 Agent 结果，本页不会展示虚构候选人。')
                .fontSize(13).fontColor('#78350F').lineHeight(21).width('100%')
              Text('你可以切换到离线 Fixture 查看完整匹配演示；切回联机模式后，课程、错题和学习计划仍继续使用真实接口。')
                .fontSize(12).fontColor('#92400E').lineHeight(19).width('100%')
              Button('前往环境设置')
                .width('100%').height(44).fontSize(14).fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF').backgroundColor('#B45309').borderRadius(12)
                .onClick(() => router.pushUrl({ url: 'pages/ApiEnvironment' }))
              Button('返回对话')
                .width('100%').height(42).fontSize(14).fontColor('#92400E')
                .backgroundColor('#FFFBEB').border({ width: 1, color: '#F59E0B' }).borderRadius(12)
                .onClick(() => ChatNavigation.returnToChat())
            }
            .width('100%').padding(18).backgroundColor('#FFFBEB').borderRadius(16)
            .border({ width: 1, color: '#FDE68A' })
          } else {
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
