# LLM 意图识别误报降级 Bug 修复报告

> 发现时间：2026-09-22
> 影响文件：`server/zhixue-agent-server/app/agent/chat_llm.py`
> 严重级别：🔴 **阻塞 AI 演示**（会让评委看到"大模型调用失败"，而模型其实一直是好的）

---

## 一、现象

配置好 `DASHSCOPE_API_KEY` 后，`/api/agent/health` 返回 `llm_ready: true`，
但 `POST /api/agent/chat` 始终返回：

```json
{"llmUsed": false, "intent": "unknown",
 "reply": "...（提示：本次大模型调用失败，已降级为本地确定性规则回复。）"}
```

前端 `ChatMain` 据此显示「本地规则兜底」标签，**看起来像大模型没接通**。

---

## 二、根因：模型成功，却被判为失败

### 关键证据

在 `detect_intent()` 的失败分支插桩，抓到：

```
DETECT: LLM 返回了但 intent 不在 KNOWN_INTENTS
raw='{"intent":"unknown"}'
parsed={'intent': 'unknown'}
```

**模型调用完全成功**，返回了合法的 `{"intent":"unknown"}`。

### 三个互相矛盾的事实

| # | 事实 | 位置 |
|---|---|---|
| 1 | `MainAgentPrompt.txt` 明确要求模型「不属于上述 6 种就返回 `{"intent":"unknown"}`」 | prompt 第 84、127 行 |
| 2 | `_LOCAL_REPLY` **专门为 `unknown` 准备了兜底文案** | `chat_llm.py:73` |
| 3 | 但 `KNOWN_INTENTS = tuple(INTENT_CARDS.keys())` **不含 `unknown`** | `chat_llm.py:63` |

于是：模型**依指令正确返回 `unknown`** → 代码判定"意图识别失败" → 丢弃结果
→ 退回关键词匹配并把 `llm_used` 置 `False` → 用户看到"大模型调用失败"。

**这是对模型成功结果的误报**，违反本项目"诚实降级、不伪装"的原则。

### 第二处同源缺陷

即使受理了 `unknown`，`unknown` 也不在 `_HANDLERS` 里（它没有对应子 Agent），
于是 `reply` 为空，落到这段：

```python
if not reply.strip():
    reply = _LOCAL_REPLY.get(intent, _LOCAL_REPLY["unknown"])
    llm_used = False        # ← 不加区分地判定失败
```

`llm_used` 又被置回 `False`，误报依旧。

---

## 三、修复

### 改动 1：受理 `unknown` 作为合法的模型返回

```python
# LLM 允许返回的意图集合 = 6 个可落地意图 + unknown。
#
# ⚠️ 为什么必须单独加 unknown：
#   若 unknown 不在受理集合里，模型依指令正确返回 unknown 时会被判为
#   "意图识别失败" → 丢弃结果 → llm_used=False
#   → 用户看到"本次大模型调用失败"，而模型其实刚刚成功响应过。
LLM_ACCEPTED_INTENTS = KNOWN_INTENTS + ("unknown",)
```

`detect_intent()` 中判定改为 `if intent in LLM_ACCEPTED_INTENTS`。

### 改动 2：区分「模型失败」与「模型成功但该意图无子 Agent」

```python
llm_attempted = llm_used   # 模型的意图判定是否真的成功
...
if not reply.strip():
    reply = _LOCAL_REPLY.get(intent, _LOCAL_REPLY["unknown"])
    if image_base64:
        reply = (...)
        llm_attempted = False
    # 只有"模型调用确实失败"才置 False
    llm_used = llm_attempted
```

---

## 四、验证

### 4.1 逐条意图实测（真实模型调用）

| 输入 | 修复前 | 修复后 |
|---|---|---|
| 帮我看看今天该学什么 | ❌ `llmUsed=False` 误报失败 | ✅ `True` / `get_suggestion` |
| 今天先学什么 | ❌ 误报 | ✅ `True` / `get_suggestion` |
| 我有哪些作业要交 | ❌ 误报 | ✅ `True` / `query_tasks` |
| 帮我找个学习搭子 | ❌ 误报 | ✅ `True` / `match_partner` |
| 帮我分析一下我的薄弱点 | ❌ 误报 | ✅ `True` / `analyze_weakness` |
| 你好呀 | ❌ 误报 | ✅ `True` / `unknown`（如实受理，不再报失败） |

真实模型回复示例：

> 最适合的学习搭子是小红，总分90分！✅ 学习目标一致：同课程、同目标，满分30分
> ✅ 时间重叠2小时（21:00-22:00），得30分 ✅ 知识互补：她强在递归，正好补你短板…

### 4.2 回归测试

```
295 passed in 7.37s        ← 零回归
```

### 4.3 live 模式全量联调

```
[PASS] 多模态调用在真 LLM 模式下确实走了模型  llmUsed=True
[PASS] 纯文本回复在真 LLM 模式下确实走了模型  llmUsed=True
结果：95/95 通过（通过率 100.0%）
契约 PASS | 后端测试 PASS | 启动 PASS | 联调 PASS
总体：PASS
```

演示基线**零漂移**：

| 指标 | 期望 | 实测 |
|---|---|---|
| `score`（√√×） | 66.67 | 66.67 ✅ |
| 全错 `score` | 0.0 | 0.0 ✅ |
| mastery | 42 → 58 | 42 → 58 ✅ |
| profileVersion | [1, 2] | [1, 2] ✅ |
| planVersion | [1, 2] | [1, 2] ✅ |
| 任务时长 | [[30,30],[45,15]] | 一致 ✅ |

---

## 五、排查过程中的两个假线索（存档以免重蹈）

### 假线索 1：以为是 Key 无效

`qwen-vl-plus` 返回 403 `AllocationQuota.FreeTierOnly`（免费额度耗尽）——
那是**模型选择问题**，不是 Key 问题。同一个 Key 调 `qwen-vl-max` 完全正常：

| 模型 | 结果 |
|---|---|
| `qwen-vl-max` | ✅ 成功 |
| `qwen-vl-plus` | ❌ 403 免费额度耗尽 |
| `qwen-plus` | ✅ 成功 |
| `qwen-turbo` | ✅ 成功 |

### 假线索 2：以为服务端跑的不是最新代码

HTTP 测试长时间显示 `intent=unknown`，而直连 Python 调用却完全正确。
一度怀疑多份模块 / `__pycache__` 陈旧。**实际原因是测试脚本本身**：

```powershell
# ❌ 错误：PowerShell 的 Invoke-RestMethod 在未指定 charset 时
#    会按 ISO-8859-1 处理中文，服务端收到的是 "??????"
Invoke-RestMethod -Body (@{message='帮我找个学习搭子'} | ConvertTo-Json)
```

服务端探针实测抓到 `MSG=????????` —— 模型面对一串问号返回 `unknown`
**本来就是正确行为**。

> ✅ **正确做法**：用 Python `urllib`/`requests` 并显式 `charset=utf-8`
> （见 `_stage6/test_chat_utf8.py`）。向本工程后端发中文请求时，
> **不要用 PowerShell 的 `Invoke-RestMethod -Body` 直接传对象**。

---

## 六、改动清单

| 文件 | 改动 |
|---|---|
| `app/agent/chat_llm.py` | 新增 `LLM_ACCEPTED_INTENTS`；`detect_intent` 受理 `unknown`；`chat()` 区分"模型失败"与"无对应子 Agent" |
| `docs/25-LLM意图识别误报降级修复报告.md` | 本文件 |

**未改动**：判分 / 掌握度 / 重规划系数 / `PRIORITY_WEIGHTS` / 契约 / `tests/conftest.py` /
`integration/` / `tools/` —— 均未触碰。

---

## 七、给后端同学的提醒

1. 这条链路的**诚实性设计值得保留**：`llmUsed` 字段是为了让前端如实区分
   "真大模型"与"本地规则兜底"。本次修复的正是它**误报**的一面。
2. 新增意图时记得同步三处：`INTENT_CARDS`、`_HANDLERS`、`_LOCAL_REPLY`。
   `unknown` 的特殊之处是**只在后两处有意缺席**（它是兜底，无需子 Agent）。
3. 若要给 `unknown` 也接一个"闲聊"子 Agent，改 `_HANDLERS` 即可，
   `LLM_ACCEPTED_INTENTS` 无需变动。
