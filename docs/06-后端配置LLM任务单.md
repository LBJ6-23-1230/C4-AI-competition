# 配置任务单 · 开启后端大模型（LLM）

> **收件人**：后端同学（持有 `DASHSCOPE_API_KEY`）
> **项目**：知学 Mate ｜ liantiao3
> **工作量**：约 **30–40 分钟**
> **目标**：把后端从「本地规则兜底」切到「真实大模型」，并验证四条链路都通
> **本单自包含**，照做即可，不需要先读别的文档

---

## 〇、一句话背景

liantiao3 的后端**已经完整接入**了大模型（两条通路，代码都在跑），
但**当前处于关闭状态**——因为后端目录下没有 `.env` 文件，读不到 Key。

实测现状：

```
GET /api/agent/health  →  {"llm_ready": false, "model": "qwen-vl-plus"}
聊天响应                →  llmUsed: false（诚实标注"本地规则生成"）
```

**你要做的事：创建一个 `.env` 文件，把 Key 填进去。** 不需要改任何代码。

---

## 一、背景知识：后端有两条 LLM 通路

配 Key 会同时激活这两条，了解它们有助于你排查问题：

| 通路 | 文件 | 用途 | 触发方式 |
|---|---|---|---|
| **A. 自然语言层** | `app/agent/chat_llm.py` | 意图识别 + 6 路子 Agent + **Qwen-VL 识图** | `POST /api/agent/chat` |
| **B. 工作流决策层** | `app/model_adapters/qwen_adapter.py` | 工作流里「下一步叫哪个 Agent」 | 工作流 `/run` 时内部调用 |

**设计纪律**（改代码时请守住）：

> LLM 只负责「生成自然语言回复 / 识别意图 / 看图」。
> **所有业务计算（判分、掌握度、优先级、重规划）一律留在确定性代码里，不进 prompt。**
>
> 这样"拔掉大模型依然能走完主链"才成立——这是答辩的核心论点之一。

---

## 二、配置步骤（3 步）

### 第 1 步：复制模板

```powershell
cd E:\C4-liantiao\liantiao3\server\zhixue-agent-server
Copy-Item .env.example .env
```

### 第 2 步：编辑 `.env`

```powershell
notepad .env
```

`.env.example` 的内容长这样，**关键是把 `DASHSCOPE_API_KEY` 那行前面的 `#` 删掉并填上真 Key**：

```ini
# ---- 通义千问 / DashScope ----
DASHSCOPE_API_KEY=sk-你的真实Key
LLM_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
LLM_MODEL=qwen-vl-plus
LLM_TIMEOUT_SECONDS=30

# ---- 服务端口 ----
PORT=5000
```

**填写规范（很容易填错，请严格照做）**：

| | 正确 | 错误 |
|---|---|---|
| 空格 | `DASHSCOPE_API_KEY=sk-abc` | `DASHSCOPE_API_KEY = sk-abc` |
| 引号 | `DASHSCOPE_API_KEY=sk-abc` | `DASHSCOPE_API_KEY="sk-abc"` |
| 注释 | 删掉行首 `#` | `# DASHSCOPE_API_KEY=sk-abc`（这样不生效） |

> ⚠️ **`LLM_MODEL=qwen-vl-plus` 建议显式写上**。
> 原因：两条通路的代码默认值不一致（聊天层默认 `qwen-vl-plus`，
> 工作流层默认 `qwen-plus`）。显式写死可以避免这个差异。

### 第 3 步：启动

```powershell
& E:\C4-liantiao\.venv-lt\Scripts\python.exe run.py
```

---

## 三、验证（必做，逐项打勾）

### ✅ 第 1 项：启动横幅

启动时应该看到这一行**变了**：

```
修改前：LLM  : 未配置 Key —— 聊天层降级为确定性规则（不伪装成 LLM 输出）
修改后：LLM  : 已配置 DASHSCOPE_API_KEY，走真实大模型
```

### ✅ 第 2 项：健康探针

另开一个 PowerShell 窗口：

```powershell
curl.exe -s http://127.0.0.1:5000/api/agent/health
```

期望（关键是 `llm_ready` 变成 `true`）：

```json
{"status":"ok","llm_ready":true,"provider":"qwen","model":"qwen-vl-plus",
 "baseUrl":"https://dashscope.aliyuncs.com/compatible-mode/v1","contractVersion":"api-contract-v0.3"}
```

### ✅ 第 3 项：真实对话（最关键）

```powershell
curl.exe -s -X POST http://127.0.0.1:5000/api/agent/chat `
  -H "Content-Type: application/json" `
  -H "X-API-Contract-Version: api-contract-v0.3" `
  -d '{\"message\":\"今天我应该先学什么？\"}'
```

期望：

```json
{"reply":"<一段大模型生成的、具体的学习建议>","intent":"get_suggestion",
 "card":{...},"llmUsed":true}
```

**判断标准**：
* ✅ `"llmUsed": true`
* ✅ `reply` 是**具体、有内容**的建议，**不是**固定模板句
* ❌ 如果 `llmUsed` 还是 `false`，说明 Key 没读到 → 回到第二节检查 `.env` 格式
* ❌ 如果 `reply` 里出现「本次大模型调用失败，已降级」→ Key 读到了但**调用失败**，看第五节

### ✅ 第 4 项：多模态识图（**重点，这里以前有 bug**）

这条链路前端对应「错题诊断页 → 拍照识别」。请**只传图片、不传文字**测试：

```powershell
# 用一个 1x1 PNG 的 base64 占位（真实测试请用真错题照片）
$img = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
$body = @{ image = $img } | ConvertTo-Json -Compress
curl.exe -s -X POST http://127.0.0.1:5000/api/agent/chat `
  -H "Content-Type: application/json" `
  -H "X-API-Contract-Version: api-contract-v0.3" `
  -d $body
```

期望：

```json
{"reply":"<模型对图片的描述/分析>","intent":"analyze_wrong","card":{...},"llmUsed":true}
```

**判断标准**：
* ✅ `"intent": "analyze_wrong"`（必须！）
* ✅ `"llmUsed": true`
* ✅ `reply` 是模型对图片的实际响应

> **为什么要专门测这条**：`detect_intent()` 原先只看文本，而"只有图片没有文字"时
> 消息会被替换成占位句「帮我分析这道题」，关键词表里没有这个词，
> 导致意图落到 `get_suggestion`，**Qwen-VL 多模态分支永远不会执行**。
> 这个缺陷已在 liantiao3 修复（`detect_intent` 新增 `has_image` 参数），
> 并补了 3 条回归测试。**你这次配置正好可以端到端验证它。**

### ✅ 第 5 项：跑一遍一键联调

```powershell
cd E:\C4-liantiao\liantiao3
& E:\C4-liantiao\.venv-lt\Scripts\python.exe integration\run_liantiao3.py --port 5097
```

**期望：退出码 0，75/75 通过。**

脚本会自动识别你是否配了 Key，并切换断言集合：

```
运行模式：真实 LLM 验证（后端已配置 DASHSCOPE_API_KEY）
...
结果：75/75 通过（通过率 100.0%）
总体：PASS
```

> 我已用假模型服务端预演过"配了 Key"的场景，**确认 75/75 与基线都不会变**。

### ✅ 第 6 项：确认演示基线没漂移

上面那次联调末尾会打印「演示基线数值表」，**必须仍然是**：

```
score（√√×）  : 66.67
全错 score     : 0.0
mastery        : 42 → 58
profileVersion : [1, 2]
planVersion    : [1, 2]
任务时长        : [[30,30], [45,15]]
```

> **我已实测：开启 LLM 后基线完全不漂移。**
> 原因就是第一节说的设计纪律——判分和掌握度是确定性代码，模型不参与。
> 工作流的决策即使被模型影响，`decide_next_step` 也只会接受**合法且可执行**的 step，
> 非法返回值自动 fallback。所以基线是安全的。
>
> **但这仍然是你最该盯的一件事**：如果这 6 个数字变了，立刻停下来上报。

---

## 四、🔒 安全要求（务必遵守）

| # | 要求 | 原因 |
|---|---|---|
| 1 | **`.env` 绝不提交 git、绝不进交付 zip** | 已在 `.gitignore`，但请再确认 |
| 2 | **不要把 Key 贴到群里 / 文档里 / 截图里** | 我已扫描过工作区，目前没有明文 Key 泄漏，保持现状 |
| 3 | **交付前跑一次检查** | 命令见下 |

交付前检查（应该**没有任何输出**）：

```powershell
Get-ChildItem E:\C4-liantiao\liantiao3 -Recurse -Force -Filter .env
```

预期：只可能列出 `.env.example`（那是模板，可以交付）；
如果列出了 `.env`，**必须删掉再打包**。

---

## 五、排错指引

| 现象 | 原因 | 解决 |
|---|---|---|
| 启动横幅仍显示"未配置 Key" | `.env` 没读到 | ① 确认文件名是 `.env` 不是 `.env.txt`；② 确认 Key 那行**没有** `#`；③ 确认等号两边无空格 |
| `llm_ready: true` 但 `llmUsed: false` | Key 读到了但**调用失败** | 看下面的排查 |
| `reply` 含"本次大模型调用失败，已降级" | 同上 | 看下面的排查 |
| `reply` 含"未接入多模态识别" | 图片没走到多模态分支 | 确认 `detect_intent` 的 `has_image` 修复在（见第三节第 4 项说明） |

**调用失败的排查顺序**：

1. **Key 是否有效 / 有没有余额**
   → 去[百炼控制台](https://bailian.console.aliyun.com/)确认
2. **网络能否访问 DashScope**

   ```powershell
   Test-NetConnection dashscope.aliyuncs.com -Port 443
   ```

3. **模型名是否正确**
   → `qwen-vl-plus` 是常用的多模态模型；若账号未开通，换成 `qwen-plus` 试试
4. **超时太短**
   → `.env` 里把 `LLM_TIMEOUT_SECONDS` 从 `30` 调到 `60`
5. **看后端控制台日志**
   → 调用失败会打印 `[chat] 子 Agent 调用失败，退回本地规则: <原因>`

> 注意：**调用失败是"安全失败"** —— 系统会退回确定性规则并如实标注
> `llmUsed: false`，不会 500，也不会伪装成大模型输出。所以配错了也能演示，只是没 AI 效果。

---

## 六、可选：换 DeepSeek（如果想省额度）

后端走 OpenAI 兼容协议，**换厂商只需改 `.env` 两个变量，代码一行不动**：

```ini
DASHSCOPE_API_KEY=sk-你的DeepSeekKey
LLM_BASE_URL=https://api.deepseek.com/v1
LLM_MODEL=deepseek-chat
```

> ⚠️ **注意**：DeepSeek 目前**不支持图片输入**，所以多模态识图会失败并降级。
> 主链和文本对话不受影响。如果要用识图功能，建议还是用 Qwen。

---

## 七、🤝 一件协作上的事（顺带提醒）

上一轮出现了**配置文件被覆盖**的问题：`run.py` 和 `tests/conftest.py`
被两端分别修改，导致一键联调报 `--quiet` 无法识别、**47 项测试变红**。

**新约定**：

```
你（后端）  →  app/** 与 tests/test_*.py
联调负责人  →  run.py 、tests/conftest.py 、contracts/ 、docs/ 、integration/
```

**具体**：本次配置**只需要新建 `.env`**，不用改任何代码。
如果你发现确实需要改 `run.py` 或 `conftest.py`，**先在群里说一声**。

---

## 八、完成后的回报清单

请把以下内容回给队长 / 联调负责人：

```
□ 启动横幅：LLM 状态那一行的实际文字
□ GET /api/agent/health 的完整返回（含 llm_ready）
□ 第 3 项对话测试的 reply 前 50 字 + llmUsed 的值
□ 第 4 项识图测试的 intent（必须是 analyze_wrong）+ llmUsed
□ 一键联调的结果：X/75 通过，退出码 = ?
□ 演示基线 6 个数字是否全部命中
□ 用的哪个模型 / 哪个厂商
□ .env 是否已确认不会进交付包
```

**如果有任何一项不符合预期，先别继续，把现象发出来一起看。**

---

## 九、配置完成后会获得什么

| 能力 | 现在 | 配完 |
|---|---|---|
| 6 路意图识别 | 关键词匹配 | **真 LLM 判定** |
| 错题拍照识图 | 固定文案"未接入多模态" | **Qwen-VL 真实识别** |
| 回复生成 | 规则模板 | **大模型自然语言** |
| 工作流决策 | 确定性 fallback | 模型决定「下一步叫谁」 |
| 前端来源标签 | 恒显示「本地规则兜底」 | 显示「**大模型生成**」 |

**答辩时可以直接演示这个对比**：同一个问题，配 Key 前后回答质量的差别，
以及界面上那个来源标签的变化——**这是"我们真的接了大模型"最直观的证据。**

---

## 十、一句话提醒

> 这次配置**不需要改任何代码**，只要新建一个 `.env` 文件。
>
> 但请务必做完第三节的 **4 项验证**——尤其是第 4 项多模态识图。
> 那条链路此前有一个"代码写了但永远走不到"的缺陷，刚修好，
> **你这次配置正好是它的第一次真实端到端验证。**
>
> 另外请盯住演示基线那 6 个数字。我实测过开启 LLM 不会让它们漂移，
> 但这是全场最不能出意外的东西。
