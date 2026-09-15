import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { AgentApiClient, ApiClientConfig } from '../api/AgentApiClient';
import { ApiEnvironmentStore } from '../api/ApiEnvironmentStore';
import { FixtureDemoStateStore } from '../api/FixtureDemoStateStore';
import { ApiFailure } from '../api/ApiResult';
import { ClientCache } from '../cache/ClientCache';
import { WorkflowSessionStore } from '../cache/WorkflowSessionStore';

@Entry
@Component
struct ApiEnvironment {
  @State baseUrl: string = '';
  @State useFixture: boolean = false;
  @State isChecking: boolean = false;
  @State message: string = '';
  private checkRequestVersion: number = 0;
  private isPageActive: boolean = false;

  aboutToAppear(): void {
    this.isPageActive = true;
    this.syncConfig();
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.checkRequestVersion++;
  }

  private syncConfig(): void {
    const config: ApiClientConfig = AgentApiClient.getConfig();
    this.baseUrl = config.baseUrl;
    this.useFixture = config.useFixture;
  }

  private applyConfig(baseUrl: string, useFixture: boolean, message: string): void {
    this.checkRequestVersion++;
    this.isChecking = false;
    const current: ApiClientConfig = AgentApiClient.getConfig();
    const enteringFixture: boolean = useFixture && !current.useFixture;
    AgentApiClient.configure({ baseUrl: baseUrl, useFixture: useFixture, timeoutMs: current.timeoutMs });
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ClientCache.clearDemoData();
    WorkflowSessionStore.clear(context);
    if (enteringFixture) {
      FixtureDemoStateStore.reset();
    }
    this.syncConfig();
    if (ApiEnvironmentStore.save(context, AgentApiClient.getConfig())) {
      this.message = `${message} 此选择会在下次启动时保留。`;
    } else {
      this.message = `${message} 当前已生效，但暂时无法保存到下次启动。`;
    }
  }

  private useOfflineDemo(): void {
    this.applyConfig(this.baseUrl, true, '已切换到 Fixture；核心流程可离线演示。');
  }

  private useEmulatorBackend(): void {
    this.applyConfig('http://10.0.2.2:5000', false, '已切换到模拟器后端，请确认电脑 5000 端口服务已启动。');
  }

  private useCustomBackend(): void {
    const value: string = this.baseUrl.trim();
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      this.message = '请输入以 http:// 或 https:// 开头的完整地址。';
      return;
    }
    this.applyConfig(value, false, '已应用真机/自定义地址，并清除了旧接口缓存。');
  }

  private async checkCurrentPlan(): Promise<void> {
    if (this.isChecking) {
      return;
    }
    this.isChecking = true;
    this.message = '';
    const requestVersion: number = ++this.checkRequestVersion;
    const result = await AgentApiClient.getCurrentPlan();
    if (!this.isPageActive || requestVersion !== this.checkRequestVersion) {
      return;
    }
    this.isChecking = false;
    if (result.ok) {
      this.message = `连接成功：${result.source === 'fixture' ? 'Fixture' : '真实后端'}返回 Plan V${result.data.version}。`;
      return;
    }
    this.message = `连接失败：${(result as ApiFailure).error.message}`;
  }

  build() {
    Column() {
      Row() {
        Text('← 返回').fontSize(14).fontColor('#64748B').onClick(() => router.back())
        Blank()
        Text('接口环境').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB')
      }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 }).backgroundColor('#FFFFFF')
      Scroll() {
        Column({ space: 16 }) {
          Text('数据源与联调地址').fontSize(23).fontWeight(FontWeight.Bold).fontColor('#111827').width('100%')
          Text('切换后会清除短期接口缓存，不会修改后端、项目代码或课程数据。')
            .fontSize(13).fontColor('#667085').lineHeight(20).width('100%')
          Button(this.useFixture ? '✓ 当前：离线 Fixture' : '使用离线 Fixture')
            .width('100%').height(48).fontSize(15).fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(12)
            .onClick(() => this.useOfflineDemo())
          Text('固定演示不依赖后端，可稳定展示 42 → 58 → Plan V2。').fontSize(12).fontColor('#667085').width('100%')
          Button(!this.useFixture && this.baseUrl === 'http://10.0.2.2:5000' ? '✓ 当前：DevEco 模拟器' : '使用 DevEco 模拟器后端')
            .width('100%').height(48).fontSize(15).fontColor('#2563EB').backgroundColor('#FFFFFF')
            .border({ width: 1, color: '#BFDBFE' }).borderRadius(12).onClick(() => this.useEmulatorBackend())
          Column({ space: 10 }) {
            Text('真机 / 自定义后端').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
            Text('手机和电脑需在同一网络，例如 http://192.168.1.23:5000。').fontSize(13).fontColor('#667085').lineHeight(19).width('100%')
            TextInput({ placeholder: 'http://192.168.x.x:5000', text: this.baseUrl })
              .width('100%').height(44).fontSize(14).backgroundColor('#F8FAFC').borderRadius(10)
              .onChange((value: string) => this.baseUrl = value)
            Button('应用此地址').width('100%').height(42).fontSize(14).fontColor('#FFFFFF')
              .backgroundColor('#2563EB').borderRadius(10).onClick(() => this.useCustomBackend())
          }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(14).border({ width: 1, color: '#E2E8F0' })
          Column({ space: 7 }) {
            Text(`当前模式：${this.useFixture ? 'Fixture 离线演示' : '真实后端'}`).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
            Text(`当前地址：${this.baseUrl}`).fontSize(12).fontColor('#667085').width('100%')
          }.width('100%').padding(14).backgroundColor('#EFF6FF').borderRadius(12)
          if (this.message.length > 0) {
            Text(this.message).fontSize(13).fontColor('#475467').lineHeight(19).width('100%').padding(12).backgroundColor('#F8FAFC').borderRadius(10)
          }
          Button(this.isChecking ? '正在检测…' : '检测当前计划接口')
            .width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            .backgroundColor('#0F766E').borderRadius(12).enabled(!this.isChecking).onClick(() => this.checkCurrentPlan())
        }.width('100%').padding(16)
      }.layoutWeight(1).backgroundColor('#F3F6FA')
    }.width('100%').height('100%')
  }
}
