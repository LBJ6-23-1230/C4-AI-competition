import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiDefaults } from '../api/ApiDefaults';
import { ApiEnvironmentStore } from '../api/ApiEnvironmentStore';
import { AuthRules, AuthSession } from '../api/AuthModels';
import { AuthStore } from '../api/AuthStore';
import { appState } from '../data/AppState';

@Entry
@Component
struct Login {
  @State nickname: string = '';
  @State showNicknameInput: boolean = false;
  @State agreed: boolean = false;
  @State errorMessage: string = '';

  private context(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private finish(session: AuthSession, offline: boolean): void {
    if (!AuthStore.save(this.context(), session)) {
      this.errorMessage = '无法保存本机身份，请重试。';
      return;
    }
    appState.applyIdentity(session);
    if (offline) {
      const config = AgentApiClient.getConfig();
      AgentApiClient.configure({ baseUrl: config.baseUrl, useFixture: true, timeoutMs: config.timeoutMs });
      ApiEnvironmentStore.save(this.context(), AgentApiClient.getConfig());
    }
    router.clear();
    router.pushUrl({ url: 'pages/ChatMain' });
  }

  private continueAsGuest(offline: boolean = false): void {
    this.finish({ userId: ApiDefaults.DEMO_USER_ID, nickname: '体验用户', source: 'guest' }, offline);
  }

  private continueWithNickname(): void {
    const error: string = AuthRules.nicknameError(this.nickname);
    if (error.length > 0) {
      this.errorMessage = error;
      return;
    }
    if (!this.agreed) {
      this.errorMessage = '请先确认本机数据使用说明。';
      return;
    }
    this.finish({ userId: `local-${Date.now()}`, nickname: this.nickname.trim(), source: 'local' }, false);
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        Column({ space: 10 }) {
          Text('知学 Mate').fontSize(34).fontWeight(FontWeight.Bold).fontColor('#1D4ED8')
          Text('会主动找你的 AI 学习搭子').fontSize(17).fontColor('#334155')
          Text('不登录也能完整体验，不让账号成为学习的门槛。')
            .fontSize(13).fontColor('#64748B').textAlign(TextAlign.Center).lineHeight(20)
        }.width('100%').margin({ top: 72, bottom: 30 })

        Button('一键体验（推荐）').width('100%').height(50).fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(14)
          .onClick(() => this.continueAsGuest(false))

        Button(this.showNicknameInput ? '收起昵称入口' : '使用昵称开始').width('100%').height(48).fontSize(15)
          .fontColor('#2563EB').backgroundColor('#FFFFFF').border({ width: 1, color: '#BFDBFE' }).borderRadius(14)
          .onClick(() => { this.showNicknameInput = !this.showNicknameInput; this.errorMessage = ''; })

        if (this.showNicknameInput) {
          Column({ space: 10 }) {
            TextInput({ placeholder: '2–16 个字符', text: this.nickname })
              .onChange((value: string) => { this.nickname = value; this.errorMessage = ''; })
              .height(48).width('100%').backgroundColor('#F8FAFC').borderRadius(12)
            Row({ space: 8 }) {
              Checkbox({ name: 'local-consent', group: 'identity' }).select(this.agreed)
                .onChange((value: boolean) => this.agreed = value)
              Text('我了解：昵称与登录状态仅保存在本机，当前不是云端账号。')
                .fontSize(12).fontColor('#64748B').lineHeight(18).layoutWeight(1)
            }.width('100%')
            Button('创建本机身份并进入').width('100%').height(46).fontSize(14).fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(12)
              .onClick(() => this.continueWithNickname())
          }.width('100%').padding(16).backgroundColor('#F8FAFC').borderRadius(16)
        }

        if (this.errorMessage.length > 0) {
          Text(this.errorMessage).fontSize(12).fontColor('#DC2626').width('100%')
            .padding(10).backgroundColor('#FEF2F2').borderRadius(10)
        }

        Text('无网络？以离线 Fixture 继续 →').fontSize(14).fontColor('#64748B')
          .onClick(() => this.continueAsGuest(true)).margin({ top: 6 })

        Text('手机号验证码、跨设备账号和云端数据同步需后端/AGC 配置后启用。')
          .fontSize(11).fontColor('#94A3B8').textAlign(TextAlign.Center).lineHeight(17).margin({ top: 20 })
      }.width('100%').padding({ left: 28, right: 28, bottom: 40 })
    }.width('100%').height('100%').backgroundColor('#FFFFFF')
  }
}
