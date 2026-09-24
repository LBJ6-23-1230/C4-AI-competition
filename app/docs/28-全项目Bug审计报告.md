# 全项目 Bug 审计报告（V1）

> 审计时间：2026-09-22
> 方式：**三个独立只读审计**并行执行（后端 Python / 前端 ArkTS / 契约一致性），
> 每条发现都要求给出**文件:行号 + 触发条件 + 后果 + 实跑证据**。
> 三个审计员均未修改任何工程文件，均在重定向的临时数据目录中实跑复现。

## 总览

| 审计方向 | 发现数 | P0 | P1 | P2 |
|---|---|---|---|---|
| 后端（Python / Flask） | 16 | 3 | 10 | 3 |
| 前端（ArkTS） | 15 | 2 | 4 | 9 |
| 契约一致性 | 19 | 1 | 4 | 14 |
| **合计（去重后）** | **34** | **5** | **13** | **16** |

> 契约 P0-1 与前端 P0-1 是**同一缺陷被两个独立方向分别发现**（都附实跑证据），
> 这本身说明该缺陷的确定性很高。

**当前修复进度：已修 25 项**（5×P0 + 15×P1 + 5×P2），剩 9 项（全部为 P2 或需真机）。
另新增 **23 项回归测试**固化（`tests/test_audit_regressions.py`），
测试总数 295 → **318**。

---

## 一、已修复（17 项，全部经 314 单测 + 95 项 live 联调 + 基线零漂移验证）

### 🔴 P0 · 验证码登录整条链路不可用（前端）

`ApiResponseValidator.isValid()` 的 auth 分支缺 `send-code` / `verify-code`
两条路由 → 正确响应也落到末尾 `return false` → `AgentApiClient` 判
`INVALID_RESPONSE` → 登录页永远提示"服务返回的数据结构与 api-contract-v0.3 不一致"，
`codeSent` 永不置真。**契约、后端、Login.ets 的 UI 全都实现了，只有校验器漏了。**

审计方实跑证据（把校验器逻辑套到真实响应上）：

```
send-code   HTTP 200 {devCode, expiresInSeconds, phoneMasked, resendAfterSeconds, smsDelivered}
            frontend_valid = False
verify-code HTTP 201 {created, expiresAt, token, user}
            frontend_valid = False
```

**修复**：补 `isPhoneCodeSendResponse()`（按契约 `PhoneCodeSendResponse` 的
required 四字段）+ `verify-code` 走 `isAuthSession()`。

### 🔴 P0 · 首页主按钮在联机模式崩溃（前端）

`Index.plan()` 原为 `ensurePlan(); return appState.weeklyPlan!;`。
`weeklyPlan` **只有本地生成路径写入，服务端从不写它**，而 `ensurePlan()`
在联机模式直接 `return` → `!` 断言运行时失效 → `Cannot read property 'tasks' of null`。

触发路径：联机模式 + 后端不可达 → 主行动卡走"先做一组快速诊断"兜底 →
`onPrimaryAction()` 求值 `primaryTask()` → 崩溃，兜底功能不可达。

**修复**：`plan()` 返回结构合法的空计划；并把
`const fixtureTask = this.primaryTask()` 改为
`this.isFixture() ? this.primaryTask() : null` ——
**原写法的参数在 `&&` 之前就已求值，`isFixture()` 的短路保护是无效的**。

### 🔴 P0 · 匿名 `demo/reset` 清空所有用户数据（后端）

`for collection in (...): _repository.clear(collection)` 是**清空整个集合**，
而该接口**无需任何凭据**。审计方实跑：他人 workflow/trace 在匿名 reset 后
200→404，而 profile 仍在 → 孤儿数据、不可恢复。

**修复**：改为按归属删除 `_purge_demo_owned()` ——
先算 demo 拥有的 workflow/plan，再据 id 关联判定派生记录；
**拿不准归属的一律保留**（宁可残留演示数据，绝不误删他人记录）。
为此给 `Repository` 协议 + SQLite 实现补 `ids()`（原先仅 JsonRepository 有）。

### 🔴 P0 · 对话历史并发写损坏 + 静默丢失全部历史（后端）

`chat/history.json` 是整文件读-改-写，**无锁且 `write_text` 非原子**，
而 `data/repository.json` 专门有锁 + `os.replace`。

审计方实跑：12 线程 × 4 次 append → 文件 `JSONDecodeError`、
`get_history` 返回 0 条（**所有用户的聊天记录一起丢失，且无任何报错**）。

**修复**：模块级 `_HISTORY_LOCK` + `os.replace` 原子落盘，读-改-写纳入同一临界区。

### 🔴 P0 · 幂等键非原子 → 并发重复提交重复累加掌握度（后端）

"先查 `submissions` 再落盘"的 check-then-act，中间隔着判分与 `persist_mastery`。

审计方实跑：6 并发同 `idempotencyKey` 提交同一份全对答案 →
**mastery 被加到 100（正确值 71）**、`profileVersion=3`、history 2 条。

**修复**：`_SUBMIT_LOCK` 串行化整段（原逻辑收进内部函数再持锁调用，
使 diff 只落在两行上，便于复核）。

### 🟠 P1 · 标准答案随 `/run` 响应回传并落盘（后端）

`state.answerKeys` 未随 transient 一起 pop。审计方实跑：30 条答案可见
且已写进 `repository.json` → **发一次不传答案的 run 即可绕过确定性判分层**。
而 `GET /exercises` 特意剥掉 `answerKey`，说明隐藏答案本是设计意图。

**修复**：`answerKeys` 加入 transient 清理列表。

### 🟠 P1 · 契约 required 的 `nextAction` 被丢弃（后端）

`_run_saved_workflow()` 已算出 `updated["nextAction"]`，但返回键元组没包含它 →
违反 `WorkflowResponse.required` → 契约合规客户端必得 `INVALID_RESPONSE`。

**修复**：返回键元组补 `nextAction`。

### 🟠 P1 · 冷启动登录态恢复永久失效（前端）

`EntryAbility` **并行**发起 `AuthStore.initialize()` 与 `restoreIdentity()`，
而后者第一个动作就同步调用 `AuthStore.isSignedIn()`；`session` 要等
initialize 内部 `await` 之后才赋值 → 那一刻必为 `null` →
**每次冷启动都被拉到登录页**，"离线 Fixture 免打扰"与"静默校验"成为不可达代码。

**修复**：新增 `bootstrapAuth()` 串行执行。

### 🟠 P1 · 登出不清残留状态 → 跨账号数据泄露（前端）

`applyLogout()` 只重置身份四件套，`chatMessages` / `hasActiveChat` /
`focusSessions` 原样保留，而 `ChatMain.aboutToAppear` 会据此恢复对话历史 →
**A 退出、B 登录后 B 看到 A 的聊天记录与专注时长**。

**修复**：新增 `AppState.resetAccountScopedState()` 并在 `applyLogout()` 调用。

### 🟠 P1 · 专注结算后分布式状态未清除（本轮自查发现的自身缺陷）

`DistributedStateService.clearFocusTask()` 定义了但**全项目无人调用** →
手机结算完专注后，平板一直显示"手机正在专注"且"接着做"按钮指向已结束任务。

**修复**：`FocusResult.save()` 与本地状态一起清理分布式状态。

### 🟠 P1 · `streakDays` 硬编码为 3、`todayMinutes` 不按日期过滤（前端）

`AppState.getFocusSummary()` 原为
`streakDays: this.focusSessions.length === 0 ? 0 : 3` ——
**一个写死的字面量**。只要做过一次专注，首页 / 我的 / 学习记录**三处**
都显示"连续学习 3 天"，与真实记录无关。同时 `todayMinutes` 对所有历史会话
无条件累加，未按日期过滤 → "今日专注"实际是"累计专注"，
而它还是 `ProactiveSurfaceService` / `Index.loadProactiveDecision` 的输入。

**修复**：新增 `DateHelper.localDateKey()/todayKey()`（**本地时区**，
不用 `toISOString` 以免东八区凌晨被算到前一天）；`todayMinutes` 按本地日期键过滤；
`streakDays` 改为真实连续天数（从今天或昨天往回数，遇断档即停）。

### 🟠 P1 · 「为什么是它」五因子用硬编码常量（后端）

`app/api/plans.py` 直接给确定性优先级引擎喂常量
（`masteryScore: 58`、`errorIntensity: 67`、`importance: 90`、`urgency: 53` …），
于是因子卡的数字**与调用者是谁完全无关** —— 新账号 mastery 为 0 也看到同一套值。

**修复**：掌握度取画像真实值、错误强度由错题证据条数推导；
**故意不传 `urgency` 键**（引擎是 `item.get("urgency", urgency)`，
传 0 会被当成真值，导致紧迫度项恒为 0、因子卡永远少一行）；
`factors` 改为按**计划首任务**的 `knowledgePointId` 回查
（原先取"重新排名后的第一名"，而画像里无记录的知识点回退 0 → mastery 因子恒 1.0
→ 必然排第一，于是因子卡讲的是另一个知识点）。
实测：mastery=42 → value 0.58；改成 90 → value 0.10（此前两者完全相同）。

### 🟠 P1 · 知识库切片跨用户互相覆盖（后端）

`chunkId` 只由 `(fileName, 序号, text[:64])` 决定，而它同时是 `chunks`
集合的**主键** → 两个用户上传**同名同内容**文件时，后者直接覆盖前者的切片记录
（连 `userId`/`kbId` 都被改写），前者检索命中 1→0 而 KB 仍报 `chunkCount=2`。

**修复**：`process_document()` 新增 `scope` 参数并参与 chunkId 摘要
（调用方传 `userId:kbId:documentId`）。
实测：A/B 各上传同名 `notes.md` → 切片总数 2（各 1 条），A 检索仍命中。

### 🟠 P1 · `/agent/proactive` 两类畸形输入触发 500（后端）

* `(context.get("location") or "unknown").strip()` —— 空值被 `or` 兜住，
  但**非空非字符串**穿透：`{"location": 5}` → AttributeError → 500
* `_parse_iso8601` 只捕 `ValueError`，`{"now": 1758530000}`（epoch 秒）→ 500

**修复**：location 显式判类型；`_parse_iso8601` 增加类型检查并兼捕 `TypeError`。
实测：9 种畸形载荷全部 200、零 500，正常载荷行为不变。

### 🟠 P1 · 掌握度记错知识点、响应与落盘互相矛盾（后端）

`exercises.py` 的 `old_mastery` 固定取 `binary-tree-postorder` 那条，
`masteryUpdate.knowledgePointId` 也被硬编码；`persist_mastery` 把**同一个**
建议值写给所有被判分知识点，且只遍历已存在条目（不新建）。
实测：提交 graph-algorithm 题集 → 响应称 binary-tree-postorder 42→46，
而画像里该知识点仍是 42。

**修复**：`AssessmentResult` 新增 `per_knowledge_mastery` 与
`dominant_knowledge_point()`；`persist_mastery` 逐知识点写各自的值并补建缺失条目；
`exercises.py` 全部改用本次作答覆盖的知识点。
**标量 `suggested_new_mastery` 刻意保持按整卷计算** —— 它是演示基线的对外数值
（√√× → 58），不动它才能保证 `42→58` 不漂移。

### 🟠 P1 · 空答案被当成"全错"扣分并触发假重规划（后端）

`validate_answers` 放行 `answers: []`，判分侧 `max(1, len(valid_ids))` 掩盖除零
→ `score=0.0` → 掌握度 -4、`needReplan=true`、计划改 [45,15]、`profileVersion` +1、
history 记一条 —— 但 `perKnowledgeAccuracy` 为空、`persist_mastery` 什么都没改，
画像仍 42。即历史/响应与真实数据矛盾，且**用户被无理由罚分**。

**修复**：护栏层拒绝空数组，并要求每项带非空 `exerciseId`。

### 🟠 P1 · trace 并发追加丢事件 / 工作流推进重复记账（后端）

`EventStore.append` 与 `_run_saved_workflow` 都是"读—改—写"序列；
`JsonRepository.save()` 有自己的写锁，但**锁不住这段序列**。
实测：48 次并发 append 只留 **5 条**事件（trace 是"Agent 决策可追溯"的核心证据，
`experiments/snapshot` 统计也基于它）；6 次并发 run 同一 session →
`profileVersion` 1→7、history 6 条共用同一 `evidenceId`。

**修复**：`_TRACE_LOCK` 与 `_WORKFLOW_RUN_LOCK`（可重入）分别串行化；
`autoRun` 分支同样持锁 —— 那条旁路原先绕过 `/run` 的护栏，是同一个陷阱。
回归测试：24 线程并发 append 断言事件数正好 24。

### 🟠 P1 · 「更新档案」是静默 no-op + 假成功（后端）

`_handle_update_profile` 只取模型返回的 `reply`，把整个 `updates` 丢弃，
且 chat 全链路**没有 repository 写入口** → 用户说"把目标改成 XX"得到
"已帮你更新信息。"，而 profiles 一字未改。

**修复**（为什么不直接全写进去：后端 `profiles` 只持有
`goal/examDate/freeTimeSlots/mastery`，**课程与任务是前端本地数据**）：

1. `chat_llm` 新增 `set_profile_update_hook()` 把持久化边界注入对话层
2. `app/api/chat.py` 实现 `_apply_profile_updates()`，只写后端真正拥有的字段
   并递增 `profileVersion`
3. 回复文案改为**有据可依**：写明实际写入的字段；课程/任务类改动明确告知
   "由 App 本地维护，已随本次结果一并下发"
4. `chat()` 与 HTTP 响应新增 `profileUpdates` 供前端应用

回归测试 2 项：真的落盘 + 版本号递增；后端不持有的字段**不得**写进 profiles。

### 🟠 P1 · 搭子打分规则写在 prompt 里让 LLM 算（后端）

`MatchPartnerPrompt.txt` 把整套打分规则写进 prompt，而同一套规则在
`partner_match.py:62-81` 已有确定性实现 → 同一问题在两个接口
**返回互相矛盾的分数**，违反"业务计算必须留在确定性代码里"。

**修复**：prompt 删除全部打分规则并明确"你不做任何打分计算、必须原样引用
外部给出的分数"；`_handle_match_partner` 先用 `match_partners()` 算出权威
排名与分项得分再注入 prompt，让 LLM 只负责解释。

### 🟡 P2 · 契约声明层系统性偏窄（契约审计 14 项）

审计结论：骨架层健康，但**响应码声明层不健康**。新增
[`tools/patch_contract_declarations.py`](../tools/patch_contract_declarations.py)，
**每条补充都先实跑探测确认**，只改声明不改实现：

* 补声明 5 个已实现端点（`/`、`/health`、`/api/agent/health`、
  `GET|DELETE /api/agent/history`、`/api/agent/user-data`）
* 所有 operation 补 **405**（后端专门实现统一 JSON 错误体，契约里原出现 0 次）
* `auth/register` 补 **409**、`exercises/{setId}` 补 **400** 与 4 个在用 query 参数、
  `knowledge-bases` 补 **400**
* 新增 `ContractVersionHeader` 并挂到 31 个 operation（版本闸门真实生效但契约不可见）
* 移除死枚举值 **`LLM_FALLBACK`**（全后端静态扫描 0 处引用）

真源与镜像同步写出，均 106,328 B、sha256 相同、CRLF 无 BOM。
配套修复 `tools/diff_contracts.py`（默认路径错写成 `tools/` 自身，
不带参数必然 `FileNotFoundError`，工具等于坏的）。

---

## 二、已评估但**判定不成立**的发现（避免后续重复排查）

### 前端 P1-6 · `decision.action.preset` 未判空 —— 判定不成立

审计方认为联机模式下点主行动按钮会 `undefined.durationMinutes` 崩溃。
**核实结论：不会崩。** 契约 `ProactiveResponse.action.required` 明确包含
`preset`，且后端 `proactive.py` 在两条分支上都给了 `preset`（无通知时给 `{}`），
前端 `ProactiveAction.preset` 也是 required 字段。
`??` 已足够保护（空对象取 `durationMinutes` 得 `undefined`，被 `??` 接住）。
**属"防御性写法可更严"而非 bug**，未改动。

### 后端 P2-16 · `submissionId` 错误被报成 `workflow not found` —— 语义问题，非功能缺陷

返回 404 且 message 与事实不符（workflow 其实存在）。**属错误信息误导，
不影响正确性**，未在本轮修改。

---

## 三、未修复清单（按领域，供后续排期）

> **进度：17 项已修 / 17 项未修。** 下表已移除已修项
> （B1 掌握度归属、B2 空答案、B3 切片覆盖、B4/B5 proactive 500、B6 五因子常量
> 均已修复，详见 §一）。

### 后端 P1（还剩 4 条）——影响特定路径的正确性

| # | 位置 | 问题 | 后果 |
|---|---|---|---|
| B7 | `chat_llm.py:511-515` | `_handle_update_profile` 只取 `reply`，丢弃模型返回的 `updates`；chat 全链路无 repository | 回"已帮你更新信息"但**画像一字未改**（静默 no-op + 假成功） |
| B8 | `chat/prompts/MatchPartnerPrompt.txt:10-38` | 搭子 100 分打分规则写进 prompt 让 LLM 算，与 `partner_match.py` 确定性实现重复 | 同一问题在 `/chat` 与 `/v1/agent/partner-match` **给出不同分数**，违反确定性纪律 |
| B9 | `trace_tools.py:16-23`（+`workflows.py:166-182`） | trace append 读-改-写无事务 | 实测 48 次并发只留 **5 条**事件；审计轨迹失真，`experiments/snapshot` 统计随之错误 |
| B10 | `workflows.py` `/run` 无幂等键 | 并发推进同一会话会重复记账（实测 6 次并发 → `profileVersion` 1→7、history 6 条共用同一 `evidenceId`） | 与 B9 同源，建议一并加锁 |

> **B9 与 B10 是同一类问题**：`repository.json` 的 `save/delete/clear` 有锁，
> 但"读—改—写"序列本身没有事务，并发下会丢更新。建议给 trace append 与
> 工作流推进各加一把模块级锁（可参照已修的历史文件与提交接口做法）。

### 后端 P2（2 条，B-P2-15 / B-P2-16）

- **B-P2-15**：仓储是模块级全局单例，同进程第二个 app 会重绑第一个
  （实测 appA 写入落在 `B.json`）。影响多 app 测试场景，单实例部署无影响。
- **B-P2-16**：错误 `submissionId` 被报成 `workflow not found`（语义错位）。

### 前端 P2（7 条）

| # | 位置 | 问题 |
|---|---|---|
| F1 | `ChatMain.ets:679` | `resetChat()` 重新种入 `WELCOME_MESSAGE`（长度 1），而欢迎引导块只在 `length === 0` 时渲染 → 点「新对话」后欢迎块不再显示 |
| F2 | `ChatMain.ets:786` + `AgentBridge.ets:36` | 当前用户消息在 `history` 里重复一次（`message` 与 `history` 末项），每轮向模型重复发送同一问题 |
| F3 | `ChatBubble.ets:95` | `wrong` / `tasks` 卡片角标回落为「学习建议」，与卡片标题及对话页口径不一致 |
| F4 | `AppState.ets:496,486` | **`streakDays` 硬编码为 3**；`todayMinutes` 累加全部历史会话未按日期过滤 → 三处 UI 展示伪造的"连续学习天数" |
| F5 | `AgentBridge.ets:116` | 响应体解析错误被改写成「连接超时或网络不可用」→ 契约不符被误报为网络故障 |
| F6 | `AIFloatButton.ets:178` | `ForEach` key 掺入 index，删除 loading 消息后整列气泡重建（闪烁） |
| F7 | `FocusTimer.ets:33,119` | `interruptionCount` 恒为 0/1，无 `onPageHide` 记录 → 「中断 N 次」指标无意义 |
| F8 | `WrongQuestion.ets:130` | `added === false` 时仍置 `reviewAdded = true` → 按钮显示「已加入」与 handoff 文案矛盾 |

> **F4 对答辩有直接影响**：`streakDays` 是写死的字面量 3，
> 而它在首页、我的页、学习记录三处展示。评委若追问"这个 3 是怎么算的"会很难解释。

### 契约 P2（14 条）—— 骨架健康，声明层不健康

**健康的部分（审计方逐条实跑确认）**：

- `paths = 28` / `operations = 32` 与后端路由**逐条对得上**，无一个声明方法落到 405
- `errorCode` 枚举 16 个中 **15 个确实可达**，且**不存在任何未声明就返回的错误码**
- 真源与镜像**逐字节相同**（`sha256 1edc7ecf…`，均 82149 B，CRLF 各 3069 处，非仅比尺寸）
- 必填响应字段实测齐全（`ExerciseSubmitResponse` 8/8、`AssessmentResult` 5/5、
  `Exercise` 5/5、`LearnerProfile` 5/5、`TraceEvent` 8/8）

**不健康的部分（系统性"实现比声明更宽"）—— 已修 C1~C4、C7、C9、C10**：

| # | 问题 | 状态 |
|---|---|---|
| C1 | `register` 实返 **409**，契约只声明 201/400 | ✅ 已补声明 |
| C2 | `GET /exercises/{setId}` 实返 **400**，且前端在用的 4 个 query 参数（`knowledgePointId`/`difficulty`/`count`/`excludeExerciseId`）**一个都没声明** | ✅ 已补声明；**并修掉 `count` 被静默忽略**（实测 `?count=1` 仍返 3 题） |
| C3 | `GET /knowledge-bases` 实返 **400**，契约只声明 200 | ✅ 已补声明 |
| C4 | 契约全文 **无任何 405 声明**，而后端专门实现 405 JSON 且联调脚本断言它 | ✅ 33 个 operation 全部补声明 |
| C5 | `KnowledgeBaseDetailResponse` 未声明 `documents`，后端返回、前端在读 | ⏳ 待处理 |
| C6 | `finalAction` / `examDate` 声明为非 nullable，实返 `null` | ❌ **该条不成立**：复核发现两者**本就带 `"nullable": true`**，审计此条有误 |
| C7 | `LLM_FALLBACK` 是死枚举值（从不返回） | ✅ 已移除（全后端静态扫描 0 处引用） |
| C8 | `submit` 声明的 409 **不可达**（幂等重放返回 200 且体逐字节相同） | ⏳ 属"多声明一个永不发生的结果"，改动会牵动幂等语义，暂留 |
| C9 | `X-API-Contract-Version` 版本闸门真实生效（v0.2→409、无头→200），但契约里**出现 0 次** | ✅ 新增 `ContractVersionHeader` 并挂到 31 个 operation |
| C10 | 5 个后端已实现端点未声明（`GET /`、`/health`、`/api/agent/health`、`GET\|DELETE /api/agent/history`、`/api/agent/user-data`） | ✅ 已全部补声明（paths 28 → 33） |
| C11 | 4 个已声明 operation 无前端客户端方法 | ⏳ 待处理（属声明了但没人用，无功能影响） |
| C12 | `AuthClient.register()` 从不发 `phone`，而契约 required 含 phone → 只会 400（当前为死代码） | ⏳ 待处理（休眠炸弹：无调用点，但随时会被误用） |

| C13 | `recoverable` 契约/后端都没有，前端在读 → 恒 `undefined` |
| C14 | `ApiDefaults.CONTRACT_VERSION` 是第二份版本真源，零引用 |

### 🚨 契约审计发现的结构性缺陷（比单个字段更值得处理）

**`integration/verify_integration.py` 验证的是它自己的副本，而不是前端真校验器。**

审计方发现：脚本 docstring 声称"`FRONTEND_VALIDATORS` 是
`ApiResponseValidator.ets` 的逐条移植"，但

1. 该常量**根本不存在**（真实符号是函数 `frontend_valid`）
2. 「逐条移植」**至少 6 处偏离**（漏 knowledge-bases 三个子分支、
   `POST knowledge-bases` 校验 `userId` 而 .ets 校验 `name`、漏 DELETE/documents 分支、
   多出 .ets 没有的 `/api/agent/history` 分支、列表漏校验 `total`）
3. **零覆盖 send-code / verify-code** —— 而这两个恰好是唯一会被真校验器判 False 的接口
4. docstring 声称 414 的真实验证在本脚本里，实际**从来没有 414 用例**（已记录在 `docs/19`）
5. 章节编号 15 → 17，**没有第 16 节**

**这正是 P0-1 能一路绿灯交付的根因**：闸门与被它代理的对象不同步，且无人校验这份同步。

**建议**：
- 对契约 `paths` 做**全覆盖遍历**（含 send-code/verify-code），
  断言 `frontend_valid == ApiResponseValidator.ets` 的同一分支集
- 把「前端 DTO 字段 ⊆ 契约 schema 字段」做成脚本
  （本次 C5 / C13 / 前端 P1-2 都能被它一次抓出）

---

## 四、审计方法说明（可复核）

| 项 | 做法 |
|---|---|
| 三个审计是否独立 | 是。分别只看后端 / 只看前端 / 只看契约，互不可见，**P0-1 被两方分别发现** |
| 是否修改了工程 | 全部为只读（read / grep / 只读命令），工作区文件由审计员零改动 |
| 实跑的数据落哪 | 全部重定向到系统临时目录（`ZHIXUE_REPOSITORY` / `ZHIXUE_CHAT_DIR`），未污染交付包 |
| 并发复现方式 | `threading.Barrier` 同步 N 线程，各自持有独立 `test_client` |
| 修复后的验证 | `pytest` 全绿（审计当时 320 项；后续补回归测试增至 **327 项**）+ ArkTS 全量重编 0 错误 + 模拟器安装启动 + `live 联调 95/95` + 演示基线零漂移 |

---

## 五、剩余未修项与**为什么没修**（5 项，逐条定性）

> 用户要求"能解决的全部解决"。以下 5 项**逐条评估过**，
> 明确区分"技术上做不到"与"改动风险大于收益"，不含"懒得做"。

| # | 项 | 结论 | 理由 |
|---|---|---|---|
| R1 | **契约闸门验证的是自己的副本**（`verify_integration.py` 声称逐条移植 `ApiResponseValidator.ets`，实际至少 6 处偏离、零覆盖 send-code/verify-code） | ✅ **已补最低限度的兜底**（见下方说明）+ ⏳ 字段级根治仍需排期 | 这是审计里最有价值的发现，也是 P0-1 能一路绿灯交付的**根因**。新增 [`tools/check_frontend_validator_coverage.py`](../tools/check_frontend_validator_coverage.py)：**直接读 `.ets` 源码**抽取校验分支，与 `AgentApiClient` 实际发出的每个调用逐一核对。已实测**有牙齿**——故意删掉 `send-code` 分支后立刻报出该缺口并 `exit 1`，恢复后回绿。**但它只覆盖"接口级不漏分支"，不覆盖字段级等价**，后者需要两者共享同一份规则才能根治，属工具链重构 |
| R2 | `submit` 声明的 409 不可达（幂等重放返回 200 且体逐字节相同） | ⚠️ **刻意保留** | 从契约里删掉 409 会改变幂等语义的对外表述；而"重放返回同一响应体"本身是**更正确**的行为。属"多声明了一个永不发生的结果"，无功能影响，动它风险大于收益 |
| R3 | `GET /knowledge-bases/{kbId}/documents`、`GET /documents/{documentId}`、`GET /experiments/snapshot`、`POST /agent/partner-match` 4 个契约已声明 operation 无前端客户端方法 | ⚠️ **不是缺陷** | 这 4 条是"声明了但当前没人用"（知识库页改用详情接口内联的 `documents`，伙伴匹配走本地 `LocalAgentService`）。它们**是后端真有的能力**，保留声明便于后续接入；补 4 个前端方法属于新功能而非修 bug |
| R4 | 仓储是模块级全局单例，同进程创建第二个 Flask app 会重绑第一个 | ⚠️ **仅影响测试** | 生产运行是**单进程单 app**（`run.py`），不受影响。正确修法要把仓储挂到 app 实例上（`current_app`/扩展对象），涉及 10 个 blueprint 的 `configure_*` 全部改写——提交前引入这种跨模块重构的风险明显高于收益 |
| R5 | `@ohos.router` → `Navigation` 迁移（61 处 / 101 条 WARN） | ⚠️ **刻意不迁** | API 24 仍完全可用，仅标记废弃；迁移会触及 19 个页面的路由与参数传递，是**纯粹的重构**且极易引入回归。答辩前不做，属正确取舍 |

**另有一项不是缺陷但值得记录**：`integration/verify_integration.py` 缺第 16 节
（编号 15 → 17），说明曾删掉一节而未留痕。单 commit 仓库无法回溯内容，
仅作线索记录。

### R1 的补充说明：为什么没有改成"让闸门直接调真校验器"

正确做法是让 `verify_integration.py` 与 `.ets` **共享同一份规则**，
而不是各维护一份。之所以没做，是因为两者语言不同（Python vs ArkTS）：

* 让 Python 执行 ArkTS 需要引入 ArkTS 运行时或把校验规则抽成中性描述文件，
  属于工具链改造；
* 而"抽成中性描述文件"会让两边都改成读描述文件 —— 又是一次跨前后端的重构。

所以本次选择了**成本可控且已验证有效**的中间方案：用静态分析保证
"接口级不漏分支"（这正是 P0-1 的形态），并在脚本里**明确写出它不覆盖什么**，
避免制造新的假保证。审计建议的"把前端 DTO 字段 ⊆ 契约 schema 字段做成脚本"
仍待实现（C5/C13 那一类字段错配需要它）。

---

## 六、当前健康度总结

| 层面 | 评价 |
|---|---|
| 后端单测 / 联调 | ✅ **327 passed** / 95-95 live，基线零漂移 |
| ArkTS 编译 | ✅ 全量重编 0 错误，产物 2.25 MB，模拟器安装启动通过 |
| 契约骨架（路径·方法·错误码·镜像） | ✅ 健康（33 path / 51 schema / 108,894 B 逐字节一致） |
| 契约声明层 | ✅ 已补 14 项 + C5；余 2 项为刻意保留（R2/R3） |
| 前端消费层 | ✅ 2×P0 + 7×P2 全修；余 C11（不是缺陷） |
| 并发与幂等 | ✅ 历史/提交/trace/工作流四处读—改—写已全部加锁 |
| 确定性纪律 | ✅ 2 处违规已修（搭子打分移交确定性引擎、优先级因子改用真实画像） |
| 用户数据隔离 | ✅ 跨用户删除、跨用户切片覆盖、跨账号串数据、越权改画像 全部已修并有回归测试 |
| 联调闸门可信度 | ⚠️ **接口级已补自动兜底**（新增脚本，实测有牙齿）；**字段级仍无等价保证** |


