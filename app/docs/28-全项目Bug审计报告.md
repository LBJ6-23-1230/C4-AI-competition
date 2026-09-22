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

---

## 一、本轮已修复（9 条，全部经 295 单测 + 95 项 live 联调验证）

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

### 后端 P1（9 条）——影响特定路径的正确性

| # | 位置 | 问题 | 后果 |
|---|---|---|---|
| B1 | `exercises.py:134-148` + `assessment_tools.py:73-76` | 掌握度用错知识点：`old_mastery` 固定取 `binary-tree-postorder`，`masteryUpdate.knowledgePointId` 也硬编码；`persist_mastery` 把同一个新值写给所有被判分知识点、且不新建缺失知识点 | 提交其它知识点题集时，**若按修复改会改动演示基线（42→58）**，需谨慎处理；当前表现为非二叉树题集的掌握度提升落不到画像上 |
| B2 | `exercises.py:121-123,140-153` + `assessment_tools.py:28-30,59-61` | `validate_answers` 放行 `answers: []` 与无效题号，`max(1,len)` 掩盖除零 → `score=0.0` | 掌握度 -4、假重规划、假 history；**若收紧校验需确认不影响既有用例** |
| B3 | `knowledge.py:379-380` + `api/knowledge.py:229,246-247` | `chunkId` 只由 `(fileName,序号,text[:64])` 决定，不含 userId/kbId/documentId | 两个用户上传同名同内容文件时，**后者的切片覆盖前者**，前者检索命中 1→0 而 KB 仍报 `chunkCount=2` |
| B4 | `proactive.py:83` | `(context.get("location") or "unknown").strip()`，location 非字符串绕过 `or` | `{"location":5}` → AttributeError → **500** |
| B5 | `proactive.py:34-40` | `_parse_iso8601` 只捕 `ValueError`，非字符串直接 `.replace()` | `{"now":123}` / `lastStudyAt` 传 epoch → **500** |
| B6 | `api/plans.py:33-37` | 五因子用硬编码 `masteryScore=58 / errorIntensity=67` 计算 | "为什么是它"整卡数字与用户数据无关、**所有人一样**（答辩主叙事被污染） |
| B7 | `chat_llm.py:511-515` | `_handle_update_profile` 只取 `reply`，丢弃模型返回的 `updates`；chat 全链路无 repository | 回"已帮你更新信息"但**画像一字未改**（静默 no-op + 假成功） |
| B8 | `chat/prompts/MatchPartnerPrompt.txt:10-38` | 搭子 100 分打分规则写进 prompt 让 LLM 算，与 `partner_match.py` 确定性实现重复 | 同一问题在 `/chat` 与 `/v1/agent/partner-match` **给出不同分数**，违反确定性纪律 |
| B9 | `trace_tools.py:16-23`（+`workflows.py:166-182`） | trace append 读-改-写无事务 | 实测 48 次并发只留 **5 条**事件；审计轨迹失真，`experiments/snapshot` 统计随之错误 |

> **B1 与 B2 需要特别小心**：它们位于演示基线的核心链路上
> （`score 66.67 / mastery 42→58 / plan [30,30]→[45,15]`）。
> 修改后**必须复跑 live 联调确认基线未漂移**，不能只看单测。

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

**不健康的部分（系统性"实现比声明更宽"）**：

| # | 问题 |
|---|---|
| C1 | `register` 实返 **409**，契约只声明 201/400 |
| C2 | `GET /exercises/{setId}` 实返 **400**，且前端在用的 4 个 query 参数（`knowledgePointId`/`difficulty`/`count`/`excludeExerciseId`）**一个都没声明** |
| C3 | `GET /knowledge-bases` 实返 **400**，契约只声明 200 |
| C4 | 契约全文 **无任何 405 声明**，而后端专门实现 405 JSON 且联调脚本断言它 |
| C5 | `KnowledgeBaseDetailResponse` 未声明 `documents`，后端返回、前端在读 |
| C6 | `finalAction` / `examDate` 声明为非 nullable，实返 `null` |
| C7 | `LLM_FALLBACK` 是死枚举值（从不返回） |
| C8 | `submit` 声明的 409 **不可达**（幂等重放返回 200 且体逐字节相同） |
| C9 | `X-API-Contract-Version` 版本闸门真实生效（v0.2→409、无头→200），但契约里**出现 0 次** |
| C10 | 5 个后端已实现端点未声明（`GET /`、`/health`、`/api/agent/health`、`GET\|DELETE /api/agent/history`、`/api/agent/user-data`） |
| C11 | 4 个已声明 operation 无前端客户端方法 |
| C12 | `AuthClient.register()` 从不发 `phone`，而契约 required 含 phone → 只会 400（当前为死代码） |
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
| 本轮修复的验证 | `pytest 295 passed` + `live 联调 95/95` + 演示基线零漂移 |

---

## 五、当前健康度总结

| 层面 | 评价 |
|---|---|
| 后端单测 / 联调 | ✅ 295 passed / 95-95 live，基线零漂移 |
| 契约骨架（路径·方法·错误码·镜像） | ✅ 健康 |
| 契约声明层（响应码·参数·字段） | ⚠️ 系统性偏窄，16 项待补 |
| 前端消费层 | ⚠️ 已修 2×P0；余 7 项 P2 |
| 并发与幂等 | ⚠️ 已修 3×P0（历史锁 / 幂等锁 / trace 无事务待修） |
| 确定性纪律 | ⚠️ 2 处违规（搭子打分进 prompt、优先级用假因子） |
| 联调闸门可信度 | ❌ **验证的是自己的副本** —— 建议优先整改 |
