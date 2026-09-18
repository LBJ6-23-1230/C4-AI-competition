import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { AuthStore } from '../api/AuthStore';
import { appState } from '../data/AppState';
import { ProactiveSettingsStore } from '../services/ProactiveSettingsStore';

@Entry
@Component
struct Account {
  @State confirmAction: string = '';
  @State proactiveEnabled: boolean = ProactiveSettingsStore.isEnabled();

  private context(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private leaveIdentity(): void {
    AuthStore.clear(this.context());
    appState.clearIdentity();
    router.clear();
    router.pushUrl({ url: 'pages/Login' });
  }

  build() {
    Column() {
      Row() {
        Text('← 返回').fontSize(14).fontColor('#64748B').onClick(() => router.back())
        Blank()
        Text('账号与隐私').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB')
      }.width('100%').padding(20).backgroundColor('#FFFFFF')

      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 8 }) {
            Text(appState.currentUser.basicInfo.name).fontSize(26).fontWeight(FontWeight.Bold).fontColor('#172033')
            Text(appState.authSession?.source === 'local' ? '本机昵称身份' : '演示体验身份')
              .fontSize(12).fontColor('#2563EB').backgroundColor('#EFF6FF').borderRadius(10)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            Text(`ID：${appState.currentUser.userId}`).fontSize(11).fontColor('#94A3B8')
          }.width('100%').alignItems(HorizontalAlign.Start).padding(20).backgroundColor('#FFFFFF').borderRadius(18)

          Column({ space: 8 }) {
            Text('隐私说明').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#172033').width('100%')
            Text('当前昵称身份只保存在本机 Preferences。离线 Fixture 不上传学习数据；真实后端模式仅按契约发送必要的用户 ID 与学习上下文。')
              .fontSize(13).fontColor('#64748B').lineHeight(21).width('100%')
          }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)

          Row({ space: 12 }) {
            Column({ space: 3 }) {
              Text('主动提醒').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#172033')
              Text('开启后，Agent 可在应用进入后台时评估是否发送系统通知。').fontSize(12).fontColor('#64748B')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.proactiveEnabled })
              .onChange((value: boolean) => {
                if (ProactiveSettingsStore.save(this.context(), value)) this.proactiveEnabled = value;
              })
          }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)

          Button('查看学习记录').width('100%').height(48).fontColor('#2563EB').backgroundColor('#FFFFFF')
            .border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
            .onClick(() => router.pushUrl({ url: 'pages/LearningHistory' }))

          if (this.confirmAction.length === 0) {
            Button('退出当前身份').width('100%').height(48).fontColor('#B45309').backgroundColor('#FFFBEB')
              .borderRadius(12).onClick(() => this.confirmAction = 'logout')
            if (appState.authSession?.source === 'local') {
              Button('清除本机身份').width('100%').height(48).fontColor('#DC2626').backgroundColor('#FEF2F2')
                .borderRadius(12).onClick(() => this.confirmAction = 'delete')
            }
          } else {
            Column({ space: 10 }) {
              Text(this.confirmAction === 'delete' ? '确认清除本机身份？' : '确认退出当前身份？')
                .fontSize(15).fontWeight(FontWeight.Bold).fontColor('#172033')
              Text('操作会返回身份选择页，不会声称删除后端数据。').fontSize(12).fontColor('#64748B')
              Row({ space: 10 }) {
                Button('取消').layoutWeight(1).fontColor('#475467').backgroundColor('#F1F5F9')
                  .onClick(() => this.confirmAction = '')
                Button('确认').layoutWeight(1).fontColor('#FFFFFF').backgroundColor('#DC2626')
                  .onClick(() => this.leaveIdentity())
              }.width('100%')
            }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(14).border({ width: 1, color: '#FECACA' })
          }
        }.width('100%').padding(20)
      }.layoutWeight(1)
    }.width('100%').height('100%').backgroundColor('#F7F8FA')
  }
}
