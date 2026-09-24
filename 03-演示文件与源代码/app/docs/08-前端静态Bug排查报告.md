# 08 · 前端静态 Bug 排查报告

> 审计对象：`app/entry/src/`（HarmonyOS ArkTS 前端，18 个页面 + 8 个服务 + 6 个 ViewModel + 6 个组件 + 3 个缓存 + 3 个工具类）
> 审计方式：**只读**静态审计（未修改任何一行代码）
> 对照物：`contracts/openapi.json`（api-contract-v0.3）、`server/zhixue-agent-server/app/**`（真实后端 Python）
> 审计日期：见 git 工作时间线

---

## 1. 一句话结论

**编译级错误数 = 0**：本工程并非"从未被编译过"——`app/.hvigor/outputs/build-logs/build.log` 显示 **2026-09-20 15:35–15:36 已成功执行过一次完整的 `assembleHap`**，`entry:default@CompileArkTS` 正常结束并产出 `app/entry/build/default/outputs/default/entry-default-unsigned.hap`，全部源文件最后修改时间为 15:02:45（**没有任何一个源文件比这次构建更新**），因此那次编译覆盖的就是当前代码；诊断结果为 **0 个 ERROR、90 个 WARN**。

**但这不等于"没有 Bug"**：`hvigor-config.json5` 里 `execution.typeCheck` 保持注释状态（默认 `false`），纯类型层面的错误（类型不匹配、字段不存在、可空性）**不在这次构建的检查范围内**；真正的问题集中在 **前后端契约** 与 **逻辑** 两类，其中最高价值的是：

> **首页的「主动决策」链路在联机模式下永远是静默分支（`action.type='none'`），`startProactiveTask()` 是死代码；**
> **登录后所有学习数据仍读写 `demo-user`（画像页硬编码、计划接口不带 userId、做题提交兜底 demo-user），登录功能对数据完全无效；**
> **`/api/v1/plans/current` 返回的 `factors` 是对象而非数组，导致「为什么是它」因子卡在联机模式永不显示。**

---

## 2. 疑似编译期错误

### 2.0 【前提修正 · 高置信度】工程已被成功编译过

| 证据 | 内容 |
|---|---|
| 构建日志 | `app/.hvigor/outputs/build-logs/build.log`，时间戳 `2026-09-20T15:35:38` → `15:36:07` |
| 关键行 | `[2026-09-20T15:36:06.938] [INFO] Finished :entry:default@CompileArkTS... after 26 s 760 ms` |
| 产物 | `app/entry/build/default/outputs/default/entry-default-unsigned.hap`（mtime `2026/9/20 15:36:07`） |
| 源文件新鲜度 | `src/main` 下所有文件 mtime 均为 `2026/9/20 15:02:45`，比构建**早 33 分钟**，计数"比构建新的文件"= 0 |
| 工具链 | `etsLoaderVersion: 6.1.1.125`、`compileSdkVersion: 24`、`arkTSVersion: undefined`（ArkTS 1.1 非静态模式）、`strictCheckerOnly: false` |
| 结论 | `src/main/**` 的语法 + ArkTS 规则检查全部通过；`src/test/**`（hypium）与 `src/ohosTest/**` 未参与该次构建 |

**这意味着**：任何"这里可能编译不过"的猜测（内联对象字面量赋给 `Object`、`private static instance: AppState;` 未初始化、`Array.from(map.entries())`、`void promise`、`as ApiResult<T>`、`@Prop` 无默认值、`@Builder` 接收函数参数…）都已被这次真实编译**证伪**，本报告不再把它们当作 Bug 列出。

**唯一的覆盖盲区（需要复核，但**不**当作已确认 Bug）**：`app/hvigor/hvigor-config.json5` 第 8 行
```json5
// "typeCheck": false,                      /* Enable typeCheck. Value: [ true | false ]. Default: false */
```
该开关未显式打开。若它正是控制 `.ets` 全量 TS 类型检查的开关，则以下 4 处**纯类型**问题不会被这次构建发现，建议在 DevEco 里打开语言服务或 `typeCheck: true` 复核一次（**置信度：低**，均为"可能"而非"确定"）：

| # | 位置 | 代码 | 疑点 |
|---|---|---|---|
| A-1 | `ExercisePractice.ets:236-238` | `if (value.needReplan && value.planDiff !== undefined) { PlanDiffCard({ value: value.planDiff }) }` | 通过属性访问做类型收窄，部分检查器不认；`PlanDiffCard` 声明为 `@Prop value: PlanDiff`（`PlanDiffCard.ets:6`），若收窄失效则报"`PlanDiff \| undefined` 不能赋给 `PlanDiff`" |
| A-2 | `FocusResult.ets:144-149` | `ForEach(['completed','partial','not_completed'], (value: string) => … onClick(() => this.assessment = value as FocusSelfAssessment)` | 把 `string` 用 `as` 收窄成字符串字面量联合；ArkTS 对 `as` 的限制比 TS 严 |
| A-3 | `LearningHistory.ets:21-24` | `ForEach(Array.from(appState.getFocusSummary().courseMinutes.entries()), (item: [string, number]) => …)` | 依赖 `Map.entries()` 迭代器 + 元组类型标注，两个都属 ArkTS 边界用法 |
| A-4 | `AgentApiClient.ets:139-147` | `const header: Record<string, string> = {…}; header['Content-Type'] = …` | `Record` 索引访问在 ArkTS 各版本支持度不一致（本次已验证通过） |

### 2.1 【高置信度】28 处 `router.*` 调用未做异常处理，编译器明确给出 WARN

编译器逐条报出 **`Function may throw exceptions. Special handling is required.`**（共 28 条，忽略大小写归并后），全部落在 `router.pushUrl / replaceUrl / back` 的调用点上。这不是风格问题——`router` 的跳转在路由表缺失、栈异常、参数非法时**真的会抛**，而绝大多数调用点位于 `@Builder` 内的 `onClick` 箭头函数里，抛出即无人接管。

**最典型的一条（也是唯一在组件内、被多个页面复用的一条）**：

```ts
// components/FollowUpCard.ets:45-50
private go(target: string): void {
  if (target.length === 0) {
    return;
  }
  router.pushUrl({ url: target });   // ← 该行被编译器点名
}
```

`FollowUpCard` 的 `go()` 会被 `primaryTarget` / `secondaryTarget` / `showAgentTraceLink` 三条路径调用（`FollowUpCard.ets:73、86、97`），而 `primaryTarget` / `secondaryTarget` 是从页面传入的**字符串**（如 `StudyTags.ets:311 'pages/ExercisePractice'`、`WrongQuestion.ets:227 'pages/ExercisePractice'`）。一旦有人写错页面名，这里抛出的异常会直接冒泡到 UI 事件循环，而不是显示一个可诊断的错误。

**建议改法**：统一包一层，
```ts
private go(target: string): void {
  if (target.length === 0) return;
  try { router.pushUrl({ url: target }); }
  catch (error) { hilog.error(0x0000, 'nav', 'pushUrl failed: %{public}s', JSON.stringify(error)); }
}
```
其余 27 处（`Index.ets:140/155/226/230/432/435/515/573/577/582/586`、`ChatMain.ets:180/184/187/520/525`、`Login.ets:87`、`Account.ets:117`、`CourseImport.ets:135`、`ChatNavigation.ets:11`、`StudySuggestion.ets:50`、`StudyTags.ets:111`、`StudyPlan.ets:45`、`FocusSetup.ets:104`、`FocusTimer.ets:131`、`EntryAbility.ets:72`、`VoiceInputService.ets:113`）可按同一模板收口。

### 2.2 【中置信度】整仓 90 条 WARN 的分布（编译器实测，非推测）

| 条数 | 告警 | 含义 | 处理建议 |
|---|---|---|---|
| 40 | `'pushUrl' has been deprecated.` | `@ohos.router` 的 API 已废弃 | 迁移到 `UIContext.getRouter()` / `Navigation`；**演示工程可不改**，但需在 README 注明 |
| 28 | `Function may throw exceptions.` | 见 2.1 | 见 2.1 |
| 14 | `'back' has been deprecated.` | 同上 | 同上 |
| 6 | `'replaceUrl' has been deprecated.` | 同上 | 同上 |
| 1 | `'getParams' has been deprecated.` | `Index.ets:65` | 同上 |
| 1 | `'clear' has been deprecated.` | `ChatNavigation.ets:10` | 同上 |

**这不是 Bug，而是"技术债 + 未来 HarmonyOS 版本可能不兼容"的风险项**，明确标注为**可暂不修改**。

---

## 3. 运行时 Bug

### R-1【高置信度】`arrayBufferToString` 用 Latin-1 逐字节解码，导入中文数据必然乱码

```ts
// services/FileParserService.ets:397-408
/**
 * 将 ArrayBuffer 转换为 UTF-8 字符串
 * 替代 TextDecoder（部分 ArkTS 环境不支持）
 */
static arrayBufferToString(buffer: ArrayBuffer): string {
  const bytes: Uint8Array = new Uint8Array(buffer);
  let result: string = '';
  for (let i: number = 0; i < bytes.length; i++) {
    result += String.fromCharCode(bytes[i]);   // ← 这是 Latin-1，不是 UTF-8
  }
  return result;
}
```

`String.fromCharCode(0xE6)` 得到的是 `æ` 而不是 UTF-8 三字节序列的首字节；对任何非 ASCII（也就是**所有中文课程名 / 作业标题**）都会产生乱码。注释自称 UTF-8，实现却是 Latin-1 —— 两者矛盾，注释即为误标。

调用点在真实导入流程上：
```ts
// pages/CourseImport.ets:45-48
const content: string = FileParserService.arrayBufferToString(buffer);
if (this.activeTab === 'courses' || this.activeTab === 'import') {
  const courses: CourseInfo[] = FileParserService.autoParseCourses(content);
```
后果：用文件方式导入一份含中文的 CSV/JSON，课程名会变成 `æ•°æ®ç»“æž„` 之类的乱码；且因为 `parseCoursesFromJSON` 的字段名恰好都是 ASCII（`courseName`/`examDate`），**JSON 能解析成功、CSV 表头匹配却会失败**，表现为"导入了 N 门课，但课程名全是乱码"或"CSV 表头缺少 courseName"。

**建议改法**：ArkTS/ArkTS 6.x 已支持 `util.TextDecoder`（`@kit.ArkTS`）：
```ts
import { util } from '@kit.ArkTS';
static arrayBufferToString(buffer: ArrayBuffer): string {
  return new util.TextDecoder('utf-8', { ignoreBOM: true }).decodeToString(new Uint8Array(buffer));
}
```
**注意**：`CourseImport.ets:369` 的手动粘贴路径（`TextArea`）不走这个方法，所以只有"文件选择导入"受影响 —— 这也解释了为什么该 Bug 可能一直没在演示中被发现。

---

### R-2【高置信度】雷达图只在 `onReady` 绘制一次，刷新画像后图表停留在旧数据

```ts
// components/RadarChart.ets:26-37
@Prop dimensions: string[] = [];
@Prop current: number[] = [];
// …
build() {
  Canvas(this.ctx)
    .width(this.canvasWidth)
    .height(this.canvasHeight)
    .onReady(() => this.drawChart())   // ← 只在首次挂载时触发一次
}
```

`Canvas.onReady` 在组件首次布局完成时触发一次；此后 `@Prop current` 变化**不会**重新触发 `onReady`，也没有任何 `@Watch('current')` 或 `onAreaChange` 重新调用 `drawChart()`。

调用点：
```ts
// pages/StudyTags.ets:307-320
FollowUpCard({ … })
Button('刷新画像')
  .enabled(!this.isLoading && !this.isStartingWorkflow)
  .onClick(() => { this.loadProfile(true); })   // ← 重新拉取 → buildChartData() → chartCurrent 变
```
`loadProfile` 会执行 `this.buildChartData()`（`StudyTags.ets:85`），`chartDims/chartCurrent` 作为 `@State` 改变 → 父组件重建 → `RadarChart` 的 `@Prop` 更新 → **但 Canvas 不会重绘**。用户点「刷新画像」后数字和进度条更新了，雷达图纹丝不动。

**首次进入不受影响**：`RadarChart` 位于 `if (this.mastery.length >= 3)` 内（`StudyTags.ets:194-205`），此时数据已就绪。所以这是"第二次以后不刷新"的 Bug。

**建议改法**：
```ts
@Prop @Watch('onDataChange') current: number[] = [];
private onDataChange(): void { this.drawChart(); }
```
（`@Watch` 回调里调用绘制即可；`Canvas` 的 `ctx` 在 `onReady` 之后长期有效。）

---

### R-3【高置信度】`getHostContext()` 强转 `UIAbilityContext` 无空值保护（5 处同型）

```ts
// pages/Index.ets:101
const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
void LearningCardService.saveDecision(context, state.decision);
```
`getHostContext()` 的返回类型是 `Context | undefined`。同型代码还出现在：

| 位置 | 代码 |
|---|---|
| `pages/Account.ets:56-58` | `private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }` |
| `pages/StudyTags.ets:105` | `WorkflowSessionStore.save(context, workflow)` |
| `pages/AgentTrace.ets:119` | `WorkflowSessionStore.clear(context)` |
| `pages/ApiEnvironment.ets:43` | `ApiEnvironmentStore.save(context, …)` |
| `pages/ChatMain.ets:680` | `requestPermissionsFromUser(context, permissions)` |

**判断**：在正常的 UIAbility 页面里 `getHostContext()` 通常非空，所以这在真机上大概率不会崩；但 `Account.context()` 被 `ProactiveSettingsStore.save` / `ProactiveSurfaceService.requestPermission` 直接使用，一旦返回 `undefined` 就是 `TypeError`。**建议统一加防御**（`if (context === undefined) return;`）并复用一处工具函数。**置信度：中**（取决于运行时环境，无法静态证明必崩）。

---

### R-4【中置信度】`AgentBridge` 把所有异常压成"网络不可用"，真实故障被吞

```ts
// services/AgentBridge.ets:102-124
if (httpResponse.responseCode >= 200 && httpResponse.responseCode < 300) {
  const resultStr: string = (httpResponse.result as string).trim();
  if (resultStr.length === 0) { throw new Error('服务未返回可解析的数据。'); }
  try {
    const data: Record<string, Object> = JSON.parse(resultStr) as Record<string, Object>;
    return AgentBridge.parseResponse(data);
  } catch (parseError) {
    throw new Error('服务返回的数据格式不正确，请检查聊天接口响应。');   // ← 会被下面的 catch 吃掉
  }
}
const serverFailure = AgentApiClient.parseServerError(httpResponse.result as string, httpResponse.responseCode);
throw new Error(`服务请求失败：${serverFailure.error.message}`);
} catch (err) {
  const detail: string = err instanceof Error ? err.message : '';
  if (detail.startsWith('服务')) {    // ← 靠中文文案前缀做控制流
    throw new Error(detail);
  }
  throw new Error('连接超时或网络不可用，请检查服务地址后重试。');
}
```

两个问题：
1. **靠错误文案前缀（`'服务'`）判断是否重新抛出**：`'服务未返回可解析的数据。'` 以"服务"开头 → 会重新抛；但 `'服务返回的数据格式不正确…'` 也以"服务"开头（碰巧成立）。任何以后新增的、不以"服务"开头的错误消息都会被静默改写成"连接超时或网络不可用"，把可诊断的问题变成不可诊断的问题。
2. `parseResponse` 内部抛出的 `'card must be an object.'` / `'llmUsed must be a boolean.'`（`AgentBridge.ets:136、144`）**不以"服务"开头** → 会被改写成"连接超时或网络不可用"。用户看到的是"网络问题"，实际是后端契约违约。

**建议改法**：定义 `class AgentBridgeError extends Error`，用 `instanceof` 判断，而不是文案前缀。

---

### R-5【中置信度】`CourseImport` 文件句柄在异常路径下泄漏

```ts
// pages/CourseImport.ets:39-43
const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
const stat: fileIo.Stat = fileIo.statSync(uri);   // ← 若此处抛错，file 永不 close
const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
fileIo.readSync(file.fd, buffer);                 // ← 单次 read 不保证读满 stat.size
fileIo.closeSync(file);
```
- `statSync` 或 `new ArrayBuffer` 抛错时 `file` 未关闭（fd 泄漏，多次失败后可能耗尽）。
- `readSync` 的返回值被忽略；大文件可能只读到一部分，`content` 被截断后 `JSON.parse` 失败，用户看到的是"解析失败"而不是"文件过大"。

**建议**：改 `try { … } finally { fileIo.closeSync(file); }`，并检查 `readSync` 的返回字节数，必要时循环读。

---

### R-6【高置信度】「图片导入课表」是空壳功能：选中的图片被丢弃，确认时导入的是内置模板

```ts
// pages/CourseImport.ets:138-156
private async pickScheduleImage(): Promise<void> {
  try {
    const photoPicker = new photoAccessHelper.PhotoViewPicker();
    const result = await photoPicker.select({ MIMEType: …, maxSelectNumber: 1 });
    if (result.photoUris.length === 0) { return; }
    this.imageImportName = `课表图片_${Date.now()}.jpg`;   // ← 文件名是编的
    this.showImageReview = true;                            // ← uri 从未被保存
    …
```

```ts
// pages/CourseImport.ets:158-169
private confirmImageImport(): void {
  const recognizedCourses: CourseInfo[] = FileParserService.autoParseCourses(
    FileParserService.generateCourseJSONTemplate()      // ← 直接解析内置模板
  );
  appState.importCourses(recognizedCourses);
  …
  this.importMessage = `已确认导入 ${recognizedCourses.length} 门课程，Agent 将据此更新学习计划。`;
}
```
后果：无论用户选哪张图，导入的永远是模板里那两门课（`数据结构 2026-07-20` / `操作系统 2026-07-28`，见 `FileParserService.ets:301-321`）。页面文案"Agent 识别课程信息后生成预览"与提示条 `已确认导入 2 门课程，Agent 将据此更新学习计划` 都是**虚假陈述**。第 280 行的小字虽然承认了"演示模式会使用本地 Agent 识别样例"，但主按钮文案与成功提示没有任何降级标注，答辩现场会被直接追问。

**建议**：要么把按钮文案改成"使用演示样例课表"并把成功提示改成"已导入演示样例课程（未接入 OCR）"，要么真正把 `result.photoUris[0]` 存起来并调用后端 OCR 接口。

---

### R-7【中置信度】登录页的两个"数据源开关"只改内存、不落盘，下次启动被回滚

```ts
// pages/Login.ets:101-106
private enterOffline(): void {
  AgentApiClient.setUseFixture(true);      // ← 只改内存
  const result: AuthResult = AuthClient.continueOffline(true);
  …
}
// pages/Login.ets:151
AgentApiClient.setUseFixture(false);       // ← 只改内存
```
而 `ApiEnvironment` 页走的是会落盘的路径：
```ts
// pages/ApiEnvironment.ets:42-54
AgentApiClient.configure({ baseUrl: baseUrl, useFixture: useFixture, timeoutMs: current.timeoutMs });
…
if (ApiEnvironmentStore.save(context, AgentApiClient.getConfig())) { … }
```
`EntryAbility.onWindowStageCreate` 启动时会 `ApiEnvironmentStore.restore(this.context)`（`EntryAbility.ets:34`）覆盖内存值。因此：用户在登录页点「无网络？用离线模式进入」→ 本次会话离线；**重启 App 后被 preferences 里的旧值覆盖**（可能是 `useFixture=false`），又去打真实后端。用户会觉得"离线模式没生效"。

**建议**：`Login.enterOffline()` / `Login.onSubmit()` 里改为调用 `AgentApiClient.configure(...)` + `ApiEnvironmentStore.save(context, …)`。

---

### R-8【中置信度】`WorkflowSessionStore.restore` 把"过期快照"注入缓存，可能导致首页显示 404 错误

```ts
// cache/WorkflowSessionStore.ets:25-32
ClientCache.cacheWorkflow({
  sessionId: sessionId,
  traceId: traceId,
  status: store.getSync(KEY_STATUS, 'running') as 'running' | 'completed' | …,
  currentStep: …,
  nextAction: …
});
```
`Index.bootstrapWorkflow()` 的逻辑是"缓存里有 workflow 就只 refreshStatus、不重建"：
```ts
// pages/Index.ets:164-179
let workflow: WorkflowResponse | null = ClientCache.getWorkflow();
let created: boolean = false;
if (workflow === null) { workflow = await this.workflowViewModel.start(…); created = workflow !== null; }
if (workflow !== null) {
  if (created) { await this.workflowViewModel.runUntilComplete(1); }
  else { await this.workflowViewModel.refreshStatus(true); }   // ← 用持久化的 sessionId 去查
}
```
若后端（或另一次 `demo/reset`）已经清掉了该 session，`GET /api/v1/workflows/{id}` 返回 **404**，`refreshStatus` 返回 `null`，`Index` 顶部的 Agent 状态条会显示"当前还没有进行中的 Agent 会话 / 服务返回 HTTP 404"，而**不会自愈**（不会清理缓存重开会话）。`cache/WorkflowSessionStore.ets:56-69` 的 `clear()` 只在 `Account` / `AgentTrace.resetDemo` / `ApiEnvironment` 三处被调用，首页没有兜底。

**建议**：`Index.bootstrapWorkflow` 在 `refreshStatus` 返回 `null` 且错误码为 404 时，`WorkflowSessionStore.clear(context)` + `ClientCache.invalidateWorkflow()` 并重新 `start()`。

---

### R-9【中置信度】`@State` 快照型初始化：主动提醒开关不会随系统权限变化刷新

```ts
// pages/Account.ets:41
@State proactiveEnabled: boolean = ProactiveSettingsStore.isEnabled();
```
`refresh()`（`Account.ets:47-54`）只在 `aboutToAppear` 调用，页面**没有** `onPageShow`。用户点开关时走 `updateProactiveSetting` 会同步状态，所以常规路径没问题；但若用户去系统设置里关掉通知权限再回到本页，`proactiveEnabled` 仍显示"开"。此外 `Toggle({ isOn: this.proactiveEnabled })`（`Account.ets:234`）是非受控的一次性绑定，与 `@State` 同步依赖重建。**属于健壮性缺陷，非必现**。

---

### R-10【中置信度】会话/学习数据全在内存，重启即丢

| 数据 | 存放 | 是否落盘 |
|---|---|---|
| `appState.focusSessions`（专注记录） | `data/AppState.ets:87` | **否** |
| `appState.weeklyPlan`（本周计划） | `AppState.ets:90` | **否** |
| `appState.courses` / `homeworkDDLs`（导入的课表/DDL） | `AppState.ets:46-47` | **否** |
| `appState.wrongQuestionImages` | `AppState.ets:76` | **否** |
| 登录态 | `AuthStore` | 是（preferences） |
| Fixture 演示态 | `FixtureDemoStateStore` | 是 |
| 接口环境 | `ApiEnvironmentStore` | 是 |

后果：用户重开 App 后，「我的记录」（`LearningHistory.ets`）的今日专注分钟 / 连续天数 / 最近专注全部归零，「课程与作业」页回到 3 门演示课程，本周计划重建。对一个以"学习数据可追溯"为卖点的作品，这是**功能级缺口**而不是 Bug，需明确标注为设计问题。

---

## 4. 逻辑 Bug

### L-1【高置信度】`ChatMain.resetChat()` 又把被注释掉要修的"机器人寒暄首屏"装了回来

```ts
// pages/ChatMain.ets:72-88（注释明确说明为什么要保持为空）
aboutToAppear(): void {
  …
  // ⚠️ 修正来源：原实现在无历史时种入一条 WELCOME_MESSAGE 气泡，
  // 结果 `messages.length === 0` 永远不成立，欢迎引导（问候语 + 输入框）
  // 从来没显示过，首屏看起来就是"一条机器人寒暄"，不是想要的对话界面。
  if (appState.hasActiveChat && appState.chatMessages.length > 0) { … }
  else { this.messages = []; }
```
```ts
// pages/ChatMain.ets:660-668（同一个文件里做了相反的事）
private resetChat(): void {
  this.messages = [WELCOME_MESSAGE];
  this.inputText = '';
  …
  appState.hasActiveChat = false;
  appState.chatMessages = '';
}
```
`WELCOME_MESSAGE` 在 `ChatMain.ets:41-47` 定义，`text` 是"晚上好，我会根据你的课程、DDL、错题和空闲时间…"。用户点右上角「新对话」后，`messages.length === 1` → `MessageList()` 的 `if (this.messages.length === 0)` 分支（`ChatMain.ets:326`）不成立 → **欢迎引导区（大号问候 + 说明）不显示，取而代之的是一条机器人寒暄**，正是注释里声明已修掉的问题。

同时 `saveMessages()` 的判定是 `hasActiveChat = this.messages.length > 1`，与 `resetChat` 写死的 1 条相互抵消：内存里显示 1 条，但 `chatMessages=''`、`hasActiveChat=false` → **退出重进后这条寒暄又消失了**，前后不一致。

**建议改法**：`resetChat()` 改为 `this.messages = [];`（与文件顶部注释一致），并让 `aboutToDisappear()` 或 `saveMessages()` 负责持久化。

---

### L-2【高置信度】FocusTimer 的"提前退出"确认可以被系统返回键完全绕过

```ts
// pages/FocusTimer.ets:23-25
aboutToDisappear(): void {
  this.stopTimer();
}
```
`FocusTimer` **没有实现 `onBackPress()`**。页面栈里按物理/手势返回键时，ArkUI 默认直接 pop 页面，于是：
- `showExitConfirm` / `showCompleteConfirm` 两个自绘对话框（`FocusTimer.ets:275-332`）完全不经过；
- `openResult()`（写 `focusResultDraft` 并跳 `FocusResult`）不执行 → 本次专注**不结算、不落盘**；
- 只有 `stopTimer()` 生效，计时数据随页面销毁丢弃。

只有页内那个 `Text('← 返回设置' / '中断专注')`（`FocusTimer.ets:218-219`）才走 `goBackToSetup()`。相对而言 `FocusSetup.ets:212` 的「开始专注」一旦进入就无法用返回键体面退出。**建议**：实现
```ts
onBackPress(): boolean {
  this.showExitConfirm = true;
  return true;   // 拦截默认返回
}
```

---

### L-3【高置信度】`goBackToSetup()` 的 if / else 两个分支完全相同（死分支）

```ts
// pages/FocusTimer.ets:148-154
private goBackToSetup(): void {
  if (this.isStrict()) {
    this.showExitConfirm = true;
    return;
  }
  this.showExitConfirm = true;   // ← 与 if 分支一字不差
}
```
两个分支没有任何行为差异，`isStrict()` 判断是多余的（真正的区分发生在 `showExitConfirm` 弹窗内部，见 `FocusTimer.ets:306`）。属于"条件分支写反/写重"，建议直接 `this.showExitConfirm = true;`。

---

### L-4【高置信度】登录页两处死代码：密码显隐三元相同、`rememberMe` 无任何效果

```ts
// pages/Login.ets:235-237
TextInput({ placeholder: '请输入密码',
            text: this.showPassword ? this.password : this.password })   // ← 两支相同
  .type(this.showPassword ? InputType.Normal : InputType.Password)
```
`text` 的三元是无效代码（显隐实际由 `.type()` 控制，所以功能是对的，纯死代码）。
```ts
// pages/Login.ets:133-135
if (this.mode === 'login' && !this.rememberMe) {
  // 不记住 → 仍可进入，只是不落盘（演示用，不阻塞流程）
}
```
**空 if 块**：注释说"不落盘"，但代码里根本没有任何后续逻辑读取 `rememberMe`（全文仅 `Login.ets:62、275-280` 读写）。`AuthClient.register()` 无论如何都会 `AuthStore.save(...)`（`AuthClient.ets:83`）。→ 「记住我」复选框**点了没有任何作用**，属于 UI 与行为不一致。

---

### L-5【中高置信度】"登录"模式实际执行的是"注册"，每次点都会新建一个账号

```ts
// pages/Login.ets:116-154
private async onSubmit(): Promise<void> {
  …
  this.busy = true;
  this.message = '';
  const result: AuthResult = await AuthClient.register(this.nickname, this.grade);   // ← 两种模式都 register
```
`mode === 'login'` 与 `mode === 'register'` 走的是同一条路径（文件头注释承认密码是占位，但没有说明"登录=新建账号"）。后果：
- 用户以为在"登录"，实际每点一次就 `POST /api/v1/auth/register` 建一个新 `u-xxxx` 账号（`auth/service.py:170-195`）；同一昵称连点两次会得到两个互不相通的账号与画像。
- 真正的"恢复已有登录态"入口（`AuthClient.login` / `AgentApiClient.authLogin`）在页面上**没有暴露**，只在 `AuthClient.restore()` 里被启动流程使用。
- 第 133-135 行的 `rememberMe` 也印证了这个分支原本想表达"登录"语义但没实现。

**建议**：`mode === 'login'` 时若本地有 `StoredSession` 则走 `AgentApiClient.authLogin({userId, token})`；否则明确提示"本机没有账号，请用「注册」建立"。

---

### L-6【中置信度】`StudySuggestion.currentTask()` 在全部完成时回退到"已完成"的任务

```ts
// pages/StudySuggestion.ets:33-39
private currentTask(): PlanTask | null {
  if (this.plan === null || this.plan.tasks.length === 0) return null;
  for (let index: number = 0; index < this.plan.tasks.length; index++) {
    if (this.plan.tasks[index].status !== 'completed') return this.plan.tasks[index];
  }
  return this.plan.tasks[0];         // ← 全部完成时返回第一个（已完成的）任务
}
```
与另外两处同义方法语义不一致：
- `Index.ets:122-128` `currentAgentTask()`：全部完成时返回 `null`；
- `StudyPlan.ets:84` 只在 `status !== 'completed'` 时渲染「开始任务」按钮。

后果：所有任务都完成后，「今日学习建议」页依然渲染 `SuggestionCard` 并给出「立即专注」按钮（`StudySuggestion.ets:70-71、95`），点击后会把一个已完成知识点写成新的专注任务。**建议**：`return null;`，让页面落到 `else` 的"暂无可执行任务"分支。

---

### L-7【高置信度】`streakDays` 是硬编码常量

```ts
// data/AppState.ets:493-499
return {
  todayMinutes: todayMinutes,
  completionRate: this.focusSessions.length === 0 ? 0 : Math.round(totalCompletion / this.focusSessions.length),
  streakDays: this.focusSessions.length === 0 ? 0 : 3,      // ← 只要有 1 条记录就恒等于 3
  courseMinutes: courseMinutes,
  recentSessions: this.focusSessions.slice(-7).reverse()
};
```
「连续学习天数」在首页（`Index.ets:756`）、账号页（`Account.ets:327`）、学习记录页（`LearningHistory.ets:17`）三处展示，永远是 `0` 或 `3`。同一页的 `todayMinutes` 统计的是**全部**会话却标为"今日"（`AppState.ets:488` 对所有 session 求和，没有按日期过滤），也是同类问题。**建议**：按 `endedAt` 日期分组计算。

---

### L-8【中置信度】演示数据的考试倒计时 / DDL 天数是写死的，与真实日期脱钩

```ts
// data/MockData.ets:54-76
{ courseId: 'c001', courseName: '数据结构', exam: { date: '2026-07-20', daysLeft: 5 }, … }
```
`daysLeft` 是常量。`DateHelper.calculateDaysLeft(dateStr)`（`utils/DateHelper.ets:148-155`）已经实现且被 `FileParserService.calcDaysLeft` 复用，但**没有用在 mock 数据上**。后果：
- `AppState.getUrgentDDLs()`（`AppState.ets:326-328`，过滤 `daysLeft <= 7`）返回的永远是同样 3 条；
- 首页 `perceptionLine()` 的"已掌握 3 门课程、N 项临近作业"、`Index.ets:712` 的"N 项临近"、`FocusSetup.ets:30` 的"高优先级课程"全部与当前真实日期无关；
- 项目内同时存在 `2026-07-15`~`2026-08-05` 的 mock 日期与 `2026-09-02/09-30` 的后端演示日期，答辩时容易被问"今天是几号、还有几天考试"。

---

### L-9【中置信度】真实后端模式下没有任何路径能把计划任务标记为已完成

全仓库 `updatePlanTaskStatus` 只有两处调用：
```ts
// pages/FocusSetup.ets:100-102
if (planTaskId !== undefined) { appState.updatePlanTaskStatus(planTaskId, 'in_progress'); }
// pages/FocusTimer.ets:185-188
if (planTaskId !== undefined) { appState.updatePlanTaskStatus(planTaskId, 'todo'); }
```
真正把它置为 `'completed'` 的只有 Fixture 分支：
```ts
// services/LocalAgentService.ets:135-145
if (session.completionRate >= 90 && session.selfAssessment === 'completed') { task.status = 'completed'; }
```
而这条路径被模式判断挡住：
```ts
// pages/FocusResult.ets:70-80
if (this.isFixture()) {
  const currentPlan = appState.weeklyPlan ?? LocalAgentService.generateWeeklyPlan(…);
  appState.setWeeklyPlan(LocalAgentService.adjustPlanAfterFocus(currentPlan, session));
  appState.latestReview = LocalAgentService.generateReviewSummary(…);
}
```
**结论**：`useFixture=false` 时，专注结束后计划任务永远停在 `in_progress`（或退回 `todo`）。连带后果：
- `AppState.getPlanProgress()`（`AppState.ets:375-381`）恒为 0% → 首页/账号页"任务完成度 0%"；
- `ReviewSummary.completedTasks()`（`ReviewSummary.ets:9-11`）恒为空 → 「已完成」区块永远显示"还没有完成任务"；
- 后端的 `/api/v1/exercises/{setId}/submit` 只更新掌握度、**不更新 PlanTask.status**（`api/exercises.py:151-171` 只重排时长与版本）。

这不是"忘记写"，而是**后端没有专注结果接口**（`FocusResult.ets:84` 的文案自己承认"后端尚未提供专注结果同步接口"）。需要产品决策：要么后端补接口，要么前端在真实模式下也调用 `LocalAgentService.adjustPlanAfterFocus` 更新**本地**计划（并如实标注为本地推导）。

---

### L-10【中置信度】路由栈增长：对 `pages/Index` 一律用 `pushUrl`，与标签栏的 `replaceUrl` 纪律不一致

`ChatMain.ets:166-174` 与 `Index.ets:501-511` 都用大段注释确立了"同级导航必须用 `replaceUrl`，否则页面栈不断增长"的纪律，但 `pages/Index` 作为"返回首页"目标时全部用的是 `pushUrl`：

| 位置 | 代码 |
|---|---|
| `pages/CourseImport.ets:526` | `router.pushUrl({ url: 'pages/Index' })` |
| `pages/ExercisePractice.ets:260` | `router.pushUrl({ url: 'pages/Index' })` |
| `pages/FocusSetup.ets:135` | `router.pushUrl({ url: 'pages/Index' })` |
| `pages/ChatMain.ets:525` | `router.pushUrl({ url: 'pages/Index' })`（工具按钮） |
| `pages/Index.ets:435` | `router.pushUrl({ url: route.target })`（`AGENT_SPECS` 里没有 Index，但 `PAGE_ROUTES.hub` 是 Index） |

`Index` 是 `@Entry` 页，每次 `pushUrl` 都会**新建一个实例**（`aboutToAppear` 重新跑一遍 `ensurePlan / loadProactiveDecision / bootstrapWorkflow`，即重复网络请求）。从对话页连续"工具 → 首页 → 返回 → 工具"，页面栈会持续堆积 `Index`，用户按返回要退很多次。

**建议**：把「返回首页」统一成一个工具方法，用 `router.replaceUrl({ url: 'pages/Index' })`（首页不是"上一层"，而是"回根"）。

---

### L-11【低置信度】`Index` 的 `onClick` 卡片与 `startProactiveTask` 的天气无关分支（见 D-5，属契约问题）

合并到 D-5 描述。

---

### L-12【低置信度】未使用代码（不构成 Bug，仅登记）

| 位置 | 说明 |
|---|---|
| `utils/Model3DRenderer.ets`（全文件，22.9 KB） | **全项目无任何 import**，死模块 |
| `components/ChatBubble.ets`（全文件） | 无任何引用的组件；`ChatMain` 内置了同名 `MessageBubble`，且两者对同一张卡片的标签文案已经分叉（`ChatBubble.ets:95-103` 返回"错题诊断/学习搭子/学习建议"，`ChatMain.ets:502-516` 返回"学情画像/学习搭子/今日任务/错题诊断/今日学习建议"） |
| `models/LearningFlowData.ets:39-133` | `learningFlowPages`、`PAGE_ROUTES` 均无引用 |
| `pages/Index.ets:890` | `const QUICK_AGENTS: AgentSpec[] = AGENT_SPECS;` 无引用 |
| `components/RadarChart.ets:4-18` | `export class RadarData` 无引用（构造函数从未被调用） |
| `data/MockData.ets:46-52、159-213` | `mockCourse`、`mockWrongQuestion(s)` 在 API 流程中无引用 |
| `data/AppState.ets:369` | `const todayFullLabel: string = DateHelper.getTodayLabel();` 与第 368 行完全重复且未使用 |
| `pages/CourseImport.ets:19`、`AppState.ets:369` | 同上类型 |

---

## 5. 前后端契约不一致

> 对照物：`contracts/openapi.json`（`info.version = api-contract-v0.3`）+ `server/zhixue-agent-server/app/**`

### C-1【高置信度】`/api/v1/plans/current` 的 `factors` 实际是**对象**，契约与前端都当数组用

**后端**（factor 的真实形状）：
```python
# app/decision/priority.py:16-28
def to_dict(self) -> dict[str, Any]:
    factor_list = [{"name": name, **values} for name, values in self.factors.items()]
    return {
        "knowledgePointId": self.knowledge_point_id,
        "score": self.total_score,
        "totalScore": self.total_score,
        "factors": dict(self.factors),        # ← dict[str, {value,weight,contribution}]，没有 name
        "factorDetails": factor_list,         # ← 这才是数组（带 name）
        "reason": self.reason,
    }
```
```python
# app/api/plans.py:38-40
if top_priority:
    plan["factors"] = top_priority[0].get("factors", {})     # ← 把 dict 塞进 plan.factors
    plan["reason"] = top_priority[0].get("reason", plan.get("reason", ""))
```

**契约**：
```json
"LearningPlan": { "properties": { "factors": { "type": "array", "items": { "$ref": "#/components/schemas/PriorityFactor" } } } }
```

**前端**：
```ts
// api/ApiModels.ets:162-169
export interface LearningPlan { … factors?: DecisionFactor[]; … }
```
```ts
// pages/StudySuggestion.ets:41
private factors(): DecisionFactor[] { return this.plan?.factors ?? []; }
// pages/StudySuggestion.ets:96-98
if (this.factors().length > 0) {                       // ← 对象没有 .length → undefined → false
  FactorBreakdownCard({ factors: this.factors(), reason: this.plan?.reason ?? '' })
}
```
**后果**：联机模式下 `plan.factors` 是 `{mastery:{…}, errorIntensity:{…}, …}`，`.length` 为 `undefined`，`undefined > 0` 为 `false` → **「为什么是它」五因子卡片在联机模式永不渲染**；而离线 Fixture（`FixtureApiTransport.factors()` 返回真数组）却渲染正常。这是一个"离线好看、联机消失"的典型假象。
**附加**：`ApiResponseValidator.isPlan`（`ApiResponseValidator.ets:112-117`）只校验 `planId/version/generatedFromProfileVersion/tasks`，**不校验 `factors`**，所以这个违约响应会被判定为"合法"，前端连错误提示都没有。

**建议**：后端 `plan["factors"] = top_priority[0].get("factorDetails", [])`；前端 validator 增加 `factors` 为数组的校验（缺失/为对象时降级为空数组并给出可诊断提示）。

---

### C-2【高置信度】`/api/v1/plans/current` 忽略登录身份，前端也不传 `userId` → 登录后读到的仍是演示计划

```python
# app/api/plans.py:16-19
@plans_api.get("/api/v1/plans/current")
def get_current_plan():
    user_id = request.args.get("userId", "demo-user")      # ← 只认 query 参数
    plans = [plan for plan in (_repository.list("plans") if _repository else [])
             if plan.get("userId", "demo-user") == user_id]
```
```ts
// api/AgentApiClient.ets:59-61
static async getCurrentPlan(): Promise<ApiResult<LearningPlan>> {
  return AgentApiClient.request<LearningPlan>(http.RequestMethod.GET, '/api/v1/plans/current');   // ← 不带任何 query
}
```
中间件确实解析了身份，但**全项目没有任何端点读取它**：
```
$ grep -n "current_user" app/**/*.py
__init__.py:46/50/60/61/66/67   ← 只有赋值，没有任何消费方
```
契约里 `/api/v1/plans/current` 声明了可选的 `UserIdQuery`（`components.parameters.UserIdQuery`，默认 `demo-user`），所以**契约本身是允许这种调用的**，但与"登录后看到自己的计划"的产品预期直接冲突。

**后果**：注册账号后，「Agent 学习计划」「今日学习建议」「练习」页展示的仍是 `demo-user` 的 `plan-demo-001`（时长 30/30、V1）。而 `auth/service.py:251-290 provision_starter_profile()` 明明给新账号预置了 `plan-{userId}` —— **这份预置计划永远不会被读到**。

**建议**：`AgentApiClient.getCurrentPlan()` 增加 `userId` 参数（`?userId=${encodeURIComponent(AuthStore.getUserId())}`），或在后端改为优先使用 `g.current_user["userId"]`。

---

### C-3【高置信度】画像页硬编码 `demo-user` → 登录用户永远看到演示画像

```ts
// cache/DemoSnapshot.ets:13
static readonly USER_ID: string = ApiDefaults.DEMO_USER_ID;   // = 'demo-user'
// pages/StudyTags.ets:74
const state = await this.viewModel.load(DemoSnapshot.USER_ID, forceRefresh);
```
`ProfileViewModel.load(userId, …)` 完全支持传入真实 userId（`ProfileViewModel.ets:23`），`AppState.currentUser.userId` 在登录后也已经是真实 `u-xxxx`（`AppState.applyLogin`，`AppState.ets:139-149`），但画像页用的是常量。

**后果**：登录用户进「学情画像」看到的是 `mastery=42` 的演示数据，而不是 `provision_starter_profile` 预置的 `mastery=0`。若演示者先注册账号再做练习，画面上"掌握度 42 → 58"的叙事与账号毫无关系。

**建议**：改为 `this.viewModel.load(appState.currentUser.userId, forceRefresh)`（`DemoSnapshot.USER_ID` 仅保留给 Fixture 语义）。

---

### C-4【高置信度】练习提交兜底 `demo-user` → 真实账号做题把掌握度写进演示账号

```ts
// pages/ExercisePractice.ets:152-155
const submissionResult: ExerciseSubmissionResult | null = await this.viewModel.submit(this.setId, {
  idempotencyKey: this.submissionKey,
  answers: exerciseAnswers              // ← 没有 userId
});
```
```ts
// viewmodels/ExerciseViewModel.ets:47-52
const request: ExerciseSubmission = {
  userId: submission.userId ?? ApiDefaults.DEMO_USER_ID,     // ← 兜底 demo-user
  sessionId: submission.sessionId ?? workflow?.sessionId,
  idempotencyKey: submission.idempotencyKey,
  answers: submission.answers
};
```
```python
# app/api/exercises.py:108, 122-124
user_id = data.get("userId", "demo-user")
profile = _repository.get("profiles", user_id) if _repository else None
if profile is None: return …("profile not found")…, 404
```
**后果**：真实账号做题 → 掌握度、evidence、submission 全部写到 `demo-user`；`/api/v1/profile/{真实userId}` 不变；新账号预置画像的 `mastery=0` 永远不会增长。

**建议**：`ExercisePractice.submit()` 显式传 `userId: appState.currentUser.userId`（`ExerciseSubmission.userId` 已是可选字段，`ApiModels.ets:199`）。

---

### C-5【高置信度】`/api/v1/agent/proactive` 在 `foreground=true` 时必定返回静默分支，首页主行动 CTA 因此永远取不到 proactive 建议

**后端**：
```python
# app/agent/proactive.py:78-91
if context.get("foreground") is True:
    return {
        "userId": user_id,
        "shouldNotify": False,
        "channel": "silent",
        "title": "",
        "body": "",
        "action": {"type": "none", "label": "", "targetPage": "", "preset": {}},
        "contextTags": [],
        "reason": "用户当前前台使用应用，暂不打扰",
        "factors": [],
        "cardData": {"taskName": "二叉树后序遍历", "knowledgePointId": "binary-tree-postorder",
                      "durationMinutes": 45, "examCountdownDays": int(days_left), "hint": ""},
    }
```
（`focusSessionActive` 分支同理，`proactive.py:48-61`；只有 `should_notify` 为真时 `action` 才是 focus，见 `proactive.py:129-134、166`）

**前端**：
```ts
// pages/Index.ets:93-96
const state = await this.proactiveViewModel.load(
  appState.currentUser.userId, daysLeft, true,       // ← foreground = true
  appState.activeFocusTask !== null && appState.focusResultDraft === null,
  lastStudyAt);
```
```ts
// pages/Index.ets:542-556
private isActionReady(): boolean {
  if (this.proactiveDecision !== null && this.proactiveDecision!.action.type === 'focus') { return true; }  // ← 恒 false
  …
}
private onPrimaryAction(): void {
  if (this.proactiveDecision !== null && this.proactiveDecision!.action.type === 'focus') {
    this.startProactiveTask();      // ← 首页永远不会进入这个分支
    return;
  }
```
**后果**：
1. `Index.ets:143-156 startProactiveTask()` 是**死代码**；
2. 首页「唯一主行动 CTA」永远退回 `currentAgentTask()` / Fixture 任务 / 诊断练习；
3. `Index.ets:348` 的注释写着"首页前台展示不等同于系统通知，因此**不依赖** shouldNotify"，但实现依赖的是 `action.type`，而后端把 `action.type` 与 `shouldNotify` **强绑定**（`proactive.py:166`）→ 注释与实现不符；
4. `Index.ets:526-528 perceptionLine()` 里的 `d.contextTags.join()` 也永远走不到（`contextTags: []`）；
5. 更隐蔽的一条：`Index.ets:100-103` 会把这份"静默决策"存进桌面卡片：
   ```ts
   if (state.decision !== null) {
     const context: common.UIAbilityContext = …;
     void LearningCardService.saveDecision(context, state.decision);
   }
   ```
   `LearningCardService.fromDecision`（`LearningCardService.ets:87-97`）取 `reason: decision.reason` → **桌面学习卡的说明文字会变成"用户当前前台使用应用，暂不打扰"**，而卡片标题却是"今日学习建议"。演示时把服务卡片加到桌面，看到的就是这句。

**建议**（二选一）：
- 后端增加"前台展示"语义参数（如 `context.foreground=false, context.surface='inApp'`）使前台也能拿到 focus 建议；或
- 前端首页不要用 `foreground=true` 调用，改为 `foreground=false` + `focusSessionActive` 精确表达，并在 UI 上明确"首页展示不受 shouldNotify 限制"。

---

### C-6【高置信度】`context.lastStudyAt` 的格式违约，导致"近 2 天未学习"触发条件永不可达

**契约**：
```json
"ProactiveRequest": { "properties": { "context": { "properties": {
  "lastStudyAt": { "type": "string", "format": "date-time", "nullable": true } } } } }
```

**前端产生值的地方**：
```ts
// pages/FocusTimer.ets:109-125
endedAt: new Date().toLocaleString()      // ← "2026/9/20 15:30:00"（中文环境），不是 ISO 8601
```
```ts
// pages/Index.ets:91-96
const recentSessions = appState.getFocusSummary().recentSessions;
const lastStudyAt: string | undefined = recentSessions.length > 0 ? recentSessions[0].endedAt : undefined;
const state = await this.proactiveViewModel.load(…, lastStudyAt);
```
```ts
// viewmodels/ProactiveViewModel.ets:34
if (lastStudyAt !== undefined && lastStudyAt.length > 0) request.context.lastStudyAt = lastStudyAt;
```
（`services/ProactiveSurfaceService.ets:19-27` 同样把 `endedAt` 塞进 `lastStudyAt`。）

**后端解析**：
```python
# app/agent/proactive.py:18-24
def _parse_iso8601(value: str | None) -> datetime | None:
    if not value: return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None            # ← "2026/9/20 15:30:00" 落到这里
```
```python
# app/agent/proactive.py:75-77, 114
gap_days = 0
if last_study_at is not None: gap_days = max(0, (now.date() - last_study_at.date()).days)
study_gap = has_study_signal and gap_days >= 2      # ← 永远 False
```
**后果**：`no_study_for_2d` 这个触发原因**永远不可能出现**，主动提醒只剩 `pending_ddl_within_2d` 与 `exam_within_7d_low_mastery`（后者依赖 `daysLeft`/`masteryScore`，前端确实传了）。演示脚本里"近 2 天未学习 → 主动提醒"这条叙事无法复现。

**建议**：前端统一用 `new Date().toISOString()` 生成 `endedAt`（`FocusSession.endedAt` 为展示用，可另加 `endedAtIso` 字段），或后端 `_parse_iso8601` 兼容 `"%Y/%m/%d %H:%M:%S"` 与 `datetime.fromtimestamp` 回退。

---

### C-7【中高置信度】后端已有 `/api/v1/agent/partner-match`，前端却按"后端未提供"禁用真实模式

**后端**：
```python
# app/api/partner_match.py:10-19
@partner_match_api.post("/api/v1/agent/partner-match")
def post_partner_match():
    data = request.get_json(silent=True) or {}
    user = data.get("user") or {"userId": data.get("userId", "demo-user")}
    candidates = data.get("candidates")
    …
    return jsonify(match_partners(user, [item for item in candidates if isinstance(item, dict)]))
```
并且已在 `create_app` 注册（`app/__init__.py:37`），契约里也有完整定义（`/api/v1/agent/partner-match` + `realModeUnavailable` 固定 false）。

**前端**：
```ts
// pages/PartnerMatch.ets:24-30
aboutToAppear(): void {
  this.realModeUnavailable = !AgentApiClient.getConfig().useFixture;
  if (this.realModeUnavailable) { generatedPartner = null; otherCandidateMatches = []; return; }
```
```ts
// pages/PartnerMatch.ets:157-162（展示给用户的文案）
Text('联机模式暂不生成搭子结果')
Text('当前后端尚未提供学习搭子匹配接口。为避免把本地规则结果伪装成在线 Agent 结果，本页不会展示虚构候选人。')
```
**后果**：联机模式下「学习搭子」页永远是空状态 + 事实错误的说明（后端明明提供了接口）；`AgentApiClient` 里也**没有** partner-match 的调用方法。这是一处"后端能力已就绪但前端未接"的集成缺口，同时页面文案会误导评审。

**建议**：在 `AgentApiClient` 补 `matchPartner(request)`，`PartnerMatch.aboutToAppear` 联机时走真实接口；实在来不及接，也至少把文案改为"联机模式未接入该接口（后端已提供 /api/v1/agent/partner-match）"。

---

### C-8【中置信度】`/api/agent/chat` 的 `history` 字段被后端完全忽略，多轮上下文静默丢失

**前端**（认真构造了历史）：
```ts
// services/AgentBridge.ets:35-51
static buildRequest(message: string, image: string | undefined, history: ChatMessage[]): AgentRequest {
  const latestHistory: ChatMessage[] = history.filter((item) => item.status === 'done').slice(-20);
  const mappedHistory: AgentHistoryItem[] = [];
  for (let i = 0; i < latestHistory.length; i++) { mappedHistory.push({ role: item.role, text: item.text }); }
  …
}
// services/AgentBridge.ets:61-66
parts.push('"history":' + JSON.stringify(history));
parts.push('"user_data":' + userDataStr);
```
**后端**：
```python
# app/api/chat.py:103-128
message = str(data.get("message") or data.get("user_message") or "").strip()
image = data.get("image")
…
frontend_data = data.get("user_data")
if not isinstance(frontend_data, dict): frontend_data = None
result = chat_llm.chat(message=message, image_base64=…, frontend_data=frontend_data)   # ← history 未被使用
```
**契约**：`LegacyChatRequest` 只声明 `message` / `user_message` / `image`（openapi `components.schemas.LegacyChatRequest`），**没有 `history`，也没有 `user_data`**。

**后果**：前端每轮都发送最多 20 条历史，后端一概不看（它用的是进程内全局 `chat_llm` 历史）。多用户/多端并发时，A 用户的对话上下文会污染 B 用户（`chat_llm.get_history()` 是全局的，见 `app/api/chat.py:150-152`）。作为"对话式学习秘书"的核心能力，这是需要明确记录的集成问题。

**建议**：契约补 `history`/`user_data`；后端把 `history` 传给 `chat_llm.chat()` 或按 sessionId 分片维护历史。

---

### C-9【低置信度】契约与前端类型的若干细节漂移（不影响运行，仅登记）

| # | 位置 | 漂移 |
|---|---|---|
| a | `api/ApiModels.ets:127-131` `ProactiveAction` | 缺 `label` 字段（后端必发，见 `proactive.py:131`；契约 required 里也有 `label`） |
| b | `api/ApiModels.ets:133-138` `ProactiveCardData` | 缺 `knowledgePointId`（契约 required 里是必填，`proactive.py:172` 必发） |
| c | `api/AuthModels.ets:15-22` `AuthUser` | 把 `grade` / `authProvider` / `createdAt` / `lastLoginAt` 声明为**必填**，契约里这 4 个都非 required。当前不产生故障（`auth/service.py:103-112 _public_user` 一律用 `.get(k, "")` 补默认值），但类型严格性弱于运行时保证 |
| d | `api/ApiModels.ets:163` `LearningPlan.planId: string \| null` | 契约 `planId` 是 `type: string` 且 required（不可空） |
| e | `api/AgentApiClient.ets:63-86` | 前端发 `knowledgePointId` / `difficulty` / `count` / `excludeExerciseId` 四个 query 参数，后端支持（`api/exercises.py:89-99`）但 openapi 的 `/api/v1/exercises/{setId}` **只声明了 path 参数** |
| f | `api/AgentApiClient.ets:180-185` `methodName()` | 映射了 `PUT`，但 `ApiResponseValidator.isValid` 没有任何 `PUT` 分支（`ApiResponseValidator.ets:3-93`），将来一旦使用 PUT 会一律判为 `INVALID_RESPONSE` |
| g | `api/ApiResponseValidator.ets:16-21` | `GET /api/v1/workflows/{id}` 的 `currentAgent`/`finalAction` 用 `isNullableString`（只接受 `null` 或 string，**不接受字段缺失**）。后端 `WorkflowStatusResponse` 两字段为 required 且可空（契约同），实测 Python 一定输出 `null` 而非省略，因此**当前安全**；但若将来改为省略字段，前端会直接判 `INVALID_RESPONSE` |

### C-10【中置信度】`/api/v1/demo/reset` 会连带清空真实账号的提交与证据

```python
# app/api/demo.py:73-80
profile, plan, trace = _demo_state()
for collection in ("traces", "submissions", "evidences", "plan_histories"):
    _repository.clear(collection)          # ← 整表清空，不按 userId 过滤
_repository.save("profiles", profile.user_id, profile.to_dict())
```
`clear(collection)` 清的是整张表，而 `profiles` / `plans` 只重置 `demo-user`。后果：已注册账号在「Agent 决策过程」页点「重置演示数据」（`AgentTrace.ets:104-125`，仅 Fixture 模式可点）时，**真实账号的 submission / evidence / trace 历史会被一并删除**，但它的 profile 掌握度还留着 → 出现"掌握度 58 但没有 evidence 支撑"的不一致。属后端侧问题，前端无法规避，但需要记录在联调风险里。

---

## 6. 路由参数一致性核对表

### 6.1 全量结论

**全工程只有 1 处 `router.getParams()` 调用**：

```ts
// pages/Index.ets:63-76
private applyInitialTab(): void {
  try {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params === undefined || params === null) { return; }
    const value: Object | undefined = params['initialTab'] as Object | undefined;
    if (typeof value === 'number' && value >= 0 && value <= 3) { this.activeTab = value as number; }
  } catch (error) { /* 无参数（正常启动）时保持默认标签，不抛错 */ }
}
```

**全工程唯一带 `params` 的跳转也只有 3 处**（同一函数内）：

```ts
// pages/ChatMain.ets:175-188
private switchTab(index: number): void {
  if (index === 0) { return; }
  if (index === 1) { router.replaceUrl({ url: 'pages/Index', params: { initialTab: 1 } }); return; }
  if (index === 2) { router.replaceUrl({ url: 'pages/Index', params: { initialTab: 2 } }); return; }
  router.replaceUrl({ url: 'pages/Index', params: { initialTab: 3 } });
}
```

→ **键名 `initialTab` 完全一致；取值范围 `1/2/3` 落在 `Index.ets:70` 的 `0 <= value <= 3` 内；语义一致**（`Index.ets:249-253` 中 `1=我的智能体 / 2=学习 / 3=我的`，与 `ChatMain.ets:143-146` 的标签序一致）。

**结论：不存在 `pushUrl` params 与 `getParams()` 键名不匹配的 Bug。** ✅

### 6.2 逐条核对表（所有跳转点）

| # | 源位置 | 目标页 | 方式 | params | 目标页读取 | 一致 |
|---|---|---|---|---|---|---|
| 1 | `ChatMain.ets:180` | `pages/Index` | replaceUrl | `{initialTab:1}` | `getParams()['initialTab']` | ✅ |
| 2 | `ChatMain.ets:184` | `pages/Index` | replaceUrl | `{initialTab:2}` | 同上 | ✅ |
| 3 | `ChatMain.ets:187` | `pages/Index` | replaceUrl | `{initialTab:3}` | 同上 | ✅ |
| 4 | `ChatMain.ets:249` | `pages/AgentTrace` | pushUrl | 无 | 无 `getParams()` | ✅ |
| 5 | `ChatMain.ets:490` | `card.targetPage`（白名单，`AgentBridge.ets:202-216`） | pushUrl | 无 | 无 | ✅ |
| 6 | `ChatMain.ets:520` | `action.targetPage` | pushUrl | 无 | 无 | ✅ |
| 7 | `ChatMain.ets:525` | `pages/Index` | pushUrl | 无 | 默认 `activeTab=1` | ⚠️ 见 6.3-① |
| 8 | `Index.ets:140/155/226` | `pages/FocusSetup` | pushUrl | 无（上下文走 `appState.setFocusTask`） | 无 | ✅ |
| 9 | `Index.ets:230/746` | `pages/LearningHistory` | pushUrl | 无 | 无 | ✅ |
| 10 | `Index.ets:330/342` | `pages/FocusSetup` / `pages/CourseImport` | pushUrl | 无 | 无 | ✅ |
| 11 | `Index.ets:432` | `pages/ChatMain` | pushUrl | 无（prompt 走 `appState.setChatPrompt`） | 无 | ✅ |
| 12 | `Index.ets:435` | `AGENT_SPECS[].routes[].target`（`Index.ets:844-885`，8 个页面） | pushUrl | 无 | 无 | ✅（全部在 `main_pages.json` 中） |
| 13 | `Index.ets:515` | `pages/ChatMain` | replaceUrl | 无 | 无 | ✅ |
| 14 | `Index.ets:573/577/582/586` | `ApiEnvironment`/`Account`/`ExercisePractice`/`AgentTrace` | pushUrl | 无 | 无 | ✅ |
| 15 | `Login.ets:87` | `pages/ChatMain` | replaceUrl | 无 | 无 | ✅ |
| 16 | `Account.ets:117` | `pages/Login` | replaceUrl | 无 | 无 | ✅ |
| 17 | `Account.ets:286/306` | `pages/PartnerMatch` | pushUrl | 无 | 无 | ✅ |
| 18 | `Account.ets:319` | `pages/LearningHistory` | pushUrl | 无 | 无 | ✅ |
| 19 | `CourseImport.ets:135` | `pages/StudyPlan` | pushUrl | 无 | 无 | ✅ |
| 20 | `CourseImport.ets:526` | `pages/Index` | pushUrl | 无 | 默认 `activeTab=1` | ⚠️ 见 6.3-① |
| 21 | `ExercisePractice.ets:260` | `pages/Index` | pushUrl | 无 | 默认 `activeTab=1` | ⚠️ 见 6.3-① |
| 22 | `FocusSetup.ets:104` | `pages/FocusTimer` | pushUrl | 无（`appState.setFocusTask` 已写） | 无 | ✅ |
| 23 | `FocusSetup.ets:135` | `pages/Index` | pushUrl | 无 | 默认 `activeTab=1` | ⚠️ 见 6.3-① |
| 24 | `FocusSetup.ets:209` | `pages/CourseImport` | pushUrl | 无 | 无 | ✅ |
| 25 | `FocusTimer.ets:131` | `pages/FocusResult` | pushUrl | 无（`appState.setFocusResultDraft` 已写） | 无 | ✅ |
| 26 | `FocusResult.ets:164` | `pages/StudyPlan` | pushUrl | 无 | 无 | ✅ |
| 27 | `StudyPlan.ets:45` / `StudySuggestion.ets:50` | `pages/FocusSetup` | pushUrl | 无（`setFocusTask`） | 无 | ✅ |
| 28 | `StudyTags.ets:111` | `pages/ExercisePractice` | pushUrl | 无 | 无 | ✅ |
| 29 | `StudyTags.ets:339` | `pages/ChatMain` | pushUrl | 无（`setChatPrompt`） | 无 | ✅ |
| 30 | `ReviewSummary.ets:112/118` | `pages/StudyPlan` / `pages/ChatMain` | pushUrl | 无 | 无 | ✅ |
| 31 | `LearningHistory.ets:34` | `pages/FocusSetup` | pushUrl | 无 | 无 | ✅ |
| 32 | `PartnerMatch.ets:166/294` | `pages/ApiEnvironment` / `pages/StudyPlan` | pushUrl | 无 | 无 | ✅ |
| 33 | `AgentTrace.ets:200` | `pages/StudyTags` | pushUrl | 无 | 无 | ✅ |
| 34 | `StudyPlan.ets:50/60`、`FocusTimer.ets:189`、`WrongQuestion.ets:256`、`StudyTags.ets:160`、`AgentTrace.ets:159`、`ApiEnvironment.ets:97`、`Account.ets:188`、`ExercisePractice.ets:268`、`ReviewSummary.ets:33`、`LearningHistory.ets:12`、`PartnerMatch.ets:62`、`StudySuggestion.ets:42`、`Index.ets` 内 `AIFloatButton` | `router.back()` | — | — | — | ✅ |
| 35 | `FollowUpCard.ets:49`（被 5 个页面复用） | 动态 `primaryTarget`/`secondaryTarget` | pushUrl | 无 | 无 | ⚠️ 见 6.3-② |
| 36 | `ChatNavigation.ets:11` | `pages/ChatMain` | `router.clear()` + pushUrl | 无 | 无 | ⚠️ 见 6.3-③ |
| 37 | `EntryAbility.ets:58/72/98` | `pages/ChatMain` → `pages/Login` / `pages/FocusSetup` | `loadContent` | — | 无 | ⚠️ 见 6.3-④ |
| 38 | `widget/pages/LearningCard.ets:15-26` | `postCardAction` → `EntryAbility` | 卡片跳转 | `{source, targetPage, taskName, durationMinutes}` | `EntryAbility.ets:142-160` 读 `source`/`taskName`/`durationMinutes` | ⚠️ 见 6.3-⑤ |

**页面注册核验**：所有跳转目标均存在于 `resources/base/profile/main_pages.json`（18 个页面），无"跳转到未注册页面"的问题。✅

### 6.3 路由相关的 5 个真实问题（不是键名不匹配，而是语义/栈问题）

**① `pushUrl('pages/Index')` 不带 `initialTab` → 落到默认的「智能体」标签**
`ExercisePractice.ets:260`「返回首页」、`FocusSetup.ets:135`「← 返回首页」、`CourseImport.ets:526`「返回首页」、`ChatMain.ets:525`「工具」全部跳到一个**新实例**的 `Index`，且 `activeTab` 保持默认值 `1`（`Index.ets:32`）。用户在"学习"标签里跳到专注设置，点「返回首页」后落在"智能体"标签 —— 与"返回首页"的字面预期不符。同时每次 `pushUrl` 都会让 `Index.aboutToAppear` 重跑一轮 `bootstrapWorkflow / loadProactiveDecision / ensurePlan`（重复请求）。**建议**：统一 `replaceUrl('pages/Index')` 或显式带 `params:{initialTab:2}`。

**② `FollowUpCard` 的目标页是纯字符串，无白名单校验**
```ts
// components/FollowUpCard.ets:45-50
private go(target: string): void {
  if (target.length === 0) { return; }
  router.pushUrl({ url: target });
}
```
对比 `AgentBridge.safeTargetPage`（`AgentBridge.ets:202-216`）对后端下发的 `targetPage` 做了白名单过滤 —— 同一类风险在组件里没有防护。当前 5 个调用点传的都是合法页面名（`ExercisePractice.ets:252/254`、`StudyTags.ets:311/313`、`WrongQuestion.ets:227`），**暂无实际故障**，属健壮性问题。

**③ `ChatNavigation.returnToChat()` 用 `router.clear()` 清空整个路由栈**
```ts
// services/ChatNavigation.ets:8-12
static returnToChat(): void {
  // 结束一次 Agent 子流程时清空旧页面，避免反复 push 聊天页把路由栈撑满。
  router.clear();
  router.pushUrl({ url: ChatNavigation.chatHome() });
}
```
被 `Index.ets:624`、`WrongQuestion.ets:52/137`、`PartnerMatch.ets:90`、`FocusResult.ets:96/167` 调用。`router.clear()` 会清掉**所有**页面（含用户原本可能想返回的上一层），属于"用清栈解决栈增长"的粗粒度做法；且 `clear` 本身已废弃（编译器 WARN）。可暂不改，但需登记为行为风险（例如用户在首页 → 练习页 → 提交 → 点「返回聊天」，会丢失首页那一层）。

**④ `EntryAbility` 会连续 `loadContent` 两次**
```ts
// entryability/EntryAbility.ets:56-66
const fromLearningCard: boolean = this.prepareLearningCardLaunch(this.pendingLaunchWant);
const initialPage: string = fromLearningCard ? 'pages/FocusSetup' : 'pages/ChatMain';
windowStage.loadContent(initialPage, (err) => { … });
void this.restoreIdentity(windowStage, fromLearningCard);
```
`restoreIdentity` 在"本地无登录态"时会再 `await windowStage.loadContent('pages/Login')`（`EntryAbility.ets:98`）。于是冷启动的正常路径是：**先加载 ChatMain（其 `aboutToAppear` 会发起 workflow/profile 请求）→ 立刻被 Login 替换**。多一次无谓的页面构建与网络请求；若 `restore()` 较慢，用户可能看到 ChatMain 一闪而过。**建议**：先 `await AuthStore`/`restore` 判定，再一次性 `loadContent`（或用空白的 splash 页兜住）。

**⑤ 卡片跳转参数的"半使用"**
`widget/pages/LearningCard.ets:20-25` 会传 `targetPage: 'pages/FocusSetup'`，但 `EntryAbility.prepareLearningCardLaunch`（`EntryAbility.ets:142-160`）只读 `source`/`taskName`/`durationMinutes`，`targetPage` 被忽略、硬编码 `loadContent('pages/FocusSetup')`（`EntryAbility.ets:57、72`）。当前两者一致（都是 FocusSetup），**无实际故障**，但 `targetPage` 是误导性冗余参数，建议删除或真正按它跳转。

---

## 7. 修复优先级建议

### P0 —— 必须改（影响演示核心叙事 / 会造成"前后端自相矛盾"）

| 编号 | 问题 | 位置 | 改动量 |
|---|---|---|---|
| C-2 | `/plans/current` 不带 `userId` → 登录后仍是演示计划 | `api/AgentApiClient.ets:59-61`（或后端 `api/plans.py:17`） | 1 行 |
| C-3 | 画像页硬编码 `demo-user` | `pages/StudyTags.ets:74` | 1 行 |
| C-4 | 做题提交兜底 `demo-user` | `pages/ExercisePractice.ets:152` 或 `viewmodels/ExerciseViewModel.ets:48` | 1 行 |
| C-1 | `plan.factors` 是对象不是数组 → 因子卡联机模式消失 | 后端 `api/plans.py:39` 改为 `factorDetails`；前端 `ApiResponseValidator.ets:112-117` 补 `factors` 校验 | 各 1 行 |
| C-5 | 首页 proactive 永远静默 → 主行动 CTA 与桌面卡片文案失真 | `pages/Index.ets:94`（foreground 语义）+ 后端 `agent/proactive.py:78` | 需产品决策 |
| C-6 | `lastStudyAt` 格式违约 → `no_study_for_2d` 永不可达 | `pages/FocusTimer.ets:124` 改 ISO；或在 `Agent/proactive.py:18` 兼容 | 1~2 行 |
| R-1 | `arrayBufferToString` 中文乱码 | `services/FileParserService.ets:401-408` | 3 行 |
| L-9 | 真实模式无路径把任务置 completed → 完成度恒 0% | `pages/FocusResult.ets:70-80` | 需决策 |

### P1 —— 应该改（真实可复现的功能/体验缺陷，改动小）

| 编号 | 问题 | 位置 |
|---|---|---|
| L-1 | 「新对话」把欢迎引导换成机器人寒暄 | `pages/ChatMain.ets:661` |
| L-2 | 返回键绕过专注退出确认 | `pages/FocusTimer.ets:23` 加 `onBackPress()` |
| L-4 | `rememberMe` 无效果 / 密码三元死代码 | `pages/Login.ets:133-135、236` |
| L-5 | 「登录」实际是「注册」，重复建号 | `pages/Login.ets:139` |
| L-6 | 全部完成时回退到已完成任务 | `pages/StudySuggestion.ets:38` |
| L-7 | `streakDays` 硬编码 3；`todayMinutes` 未按日过滤 | `data/AppState.ets:488、496` |
| R-2 | 雷达图刷新后不重绘 | `components/RadarChart.ets:26-37` |
| R-6 | 「图片导入课表」是空壳（应改文案或补 OCR） | `pages/CourseImport.ets:138-169` |
| R-7 | 登录页数据源开关不落盘 | `pages/Login.ets:102、151` |
| C-7 | 搭子页文案与后端事实不符（后端已有接口） | `pages/PartnerMatch.ets:24-30、157-162` |
| 2.1 | `router.*` 未做异常处理（编译器已告警 28 处） | 至少覆盖 `components/FollowUpCard.ets:49` 与 `services/ChatNavigation.ets:11` |

### P2 —— 可以不改（记录在案，答辩时如实说明）

| 编号 | 问题 | 理由 |
|---|---|---|
| 2.2 | 90 条 deprecated WARN（`pushUrl`/`back`/`replaceUrl`/`getParams`/`clear`） | `@ohos.router` 在 API 24 仍可用；迁移到 `Navigation` 属于重构，收益低于风险 |
| L-8 | mock 数据的 `daysLeft` 写死 | 演示数据本就是 2026 年固定日期；如担心被追问，只需在 README 注明"演示基线日期固定" |
| C-8 | `/api/agent/chat` 忽略 `history` | 后端有全局历史，单用户演示下表现正常；多端并发才会暴露 |
| C-9 | 契约字段漂移 a~g | 均不产生运行故障（已逐条验证后端一定会补默认值） |
| C-10 | `demo/reset` 连带清空真实账号的 submissions | 后端问题，且 `AgentTrace` 的重置按钮仅在 Fixture 模式可见 |
| R-3 | `getHostContext() as UIAbilityContext` 无空值保护 | 正常 UIAbility 页面下非空；建议顺手加防御但非必改 |
| R-5 | `openSync` 异常路径 fd 泄漏 | 触发概率低；顺手改 `try/finally` 即可 |
| R-8 | 持久化 workflow 会话可能 404 不自愈 | 只在"后端被重置过"时出现，手动进「接口环境」清缓存即可恢复 |
| R-9/R-10 | 开关不随系统权限刷新 / 学习数据不落盘 | 属设计取舍，需产品决策而非代码修补 |
| L-10 / 6.3-①~⑤ | 路由栈增长与 `getParams` 相关行为 | 不影响功能正确性；建议统一「返回首页」为 `replaceUrl` 作为低成本改善 |
| L-12 | 6 处死代码（`Model3DRenderer`、`ChatBubble`、`learningFlowPages`、`QUICK_AGENTS`、`RadarData`、`mockWrongQuestion`） | 不影响构建与运行；若参加代码规范评审可删除，`Model3DRenderer.ets`（22.9 KB）最值得删 |

### 需要真机 / 完整编译才能最终确认的项（明确标注）

1. **第 2.0 节的 4 条类型层面疑点（A-1 ~ A-4）**：本次构建 `execution.typeCheck` 未开启，无法判定；建议在 DevEco 里打开该开关或直接看 IDE 的 Problems 面板复核。**当前按"未确认"处理，不计入 Bug 数**。
2. **R-3 / R-9**：依赖 `getHostContext()` 的实际返回与 `Toggle` 的受控行为，需真机确认。
3. **R-2**：`Canvas.onReady` 只触发一次属 ArkUI 既有语义，但"`@Prop` 变化是否会导致 `Canvas` 组件重建从而再次触发 `onReady`"在个别 API 版本上可能有差异 —— 若真机上刷新后图表确实变了，则本条降级为"低风险"。
4. **C-5 第 5 点（桌面卡片显示"用户当前前台使用应用，暂不打扰"）**：需在真机上把服务卡片加到桌面才能看到最终渲染；代码路径已确认。

---

## 附录 A · 与既有结论的对齐（避免重复报）

以下 4 项在任务说明中已标注为"不是问题"，本次审计独立复核后**确认不必再报**，并给出复核依据：

| 项 | 复核结论 |
|---|---|
| `ApiDefaults.ets` 的 baseUrl 已统一 | ✅ `ApiDefaults.ets:25` 只有一处 `DEFAULT_BASE_URL`；`AgentApiClient.ets:26` 引用它；页面中无第二个 IP 常量（`ApiEnvironment.ets:62` 用的是 `ApiDefaults.DEFAULT_BASE_URL`） |
| `AgentBridge.ets` 的 `llmUsed` 已实现 | ✅ 解析在 `AgentBridge.ets:131、141-147`；渲染在 `ChatMain.ets:413-420`；后端确实透传（`api/chat.py:143`）；契约已声明（`LegacyChatResponse.llmUsed`） |
| `WorkflowViewModel.isAwaitingAnswers()` 已实现 | ✅ `WorkflowViewModel.ets:88-91`，并在 `runUntilComplete` 的 `:78-82` 正确使用（命中时不继续空转、不报错） |
| `ProactiveViewModel` 的 `status:'pending', started:false` 是刻意写死 | ✅ 确认 `ProactiveViewModel.ets:40-46` 硬编码；`HomeworkDDL`（`models/AgentModels.ets:55-63`）确实没有 `status` 字段，`AppState.removeDDL`（`AppState.ets:248-257`）会把已完成项移出数组 —— 不构成 Bug |

## 附录 B · 审计方法与可复核命令

```powershell
# 1) 证明工程已被成功编译（本报告第 2.0 节的核心证据）
Select-String -Path "app\.hvigor\outputs\build-logs\build.log" -Pattern "Finished :entry:default@CompileArkTS"
Get-ChildItem "app\entry\src\main" -Recurse -File | Where-Object { $_.LastWriteTime -gt (Get-Date "2026-09-20 15:36:07") } | Measure-Object
Get-Item "app\entry\build\default\outputs\default\entry-default-unsigned.hap" | Select-Object LastWriteTime

# 2) 导出全部 90 条 ArkTS 诊断
$raw = Get-Content "app\.hvigor\outputs\build-logs\build.log" -Raw
$clean = $raw -replace "\x1b\[[0-9;]*m",""
[regex]::Matches($clean, "ArkTS:WARN File: ([^\r\n]+)\r?\n([^\r\n]*)") |
  ForEach-Object { [pscustomobject]@{Loc=$_.Groups[1].Value.Trim(); Msg=$_.Groups[2].Value.Trim()} } |
  Group-Object Msg | Sort-Object Count -Descending | Select-Object Count, Name

# 3) 全工程 getParams / params 清单（第 6 节的依据）
Select-String -Path "app\entry\src\main\ets\**\*.ets" -Pattern "getParams|params:"

# 4) 后端身份是否被任何端点使用（C-2 的依据）
Select-String -Path "server\zhixue-agent-server\app\api\*.py","server\zhixue-agent-server\app\*.py" -Pattern "current_user"
```

---

*报告完 · 全文只读审计，未修改任何源码文件。*
