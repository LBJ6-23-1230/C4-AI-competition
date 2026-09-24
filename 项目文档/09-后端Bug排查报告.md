# 后端运行时 Bug 排查报告（知学 Mate · zhixue-agent-server）

| 项目 | 内容 |
| --- | --- |
| 排查对象 | `E:\C4-liantiao\liantiao3\server\zhixue-agent-server` |
| 排查方式 | **真实启动服务 + HTTP 实测**（非只读代码推断），共发出 **800+ 次真实请求** |
| 解释器 | `E:\C4-liantiao\.venv-lt\Scripts\python.exe`（Python 3.12.13） |
| 启动命令 | `cd E:\C4-liantiao\liantiao3\server\zhixue-agent-server; $env:PORT=5211; & E:\C4-liantiao\.venv-lt\Scripts\python.exe run.py --quiet` |
| 使用端口 | **5211 / 5212**（避开 5283/5284/5285 等已占用端口） |
| 契约真源 | `E:\C4-liantiao\liantiao3\contracts\openapi.json`（`api-contract-v0.3`，19 条 path / 36 个 schema；已用 Python `json` 校验为合法 JSON） |
| 请求头 | `X-API-Contract-Version: api-contract-v0.3` |
| 排查性质 | **只读**：未修改任何项目源码；仅写入本报告。本报告覆盖并替代同路径下的旧版本 |
| 结束状态 | 已恢复演示基线（42 / v1 / [30,30]）；**已停掉全部由本次排查启动的 Python 进程（当前 `python` 进程数 = 0）** |

> 说明：本次排查期间，`data/repository.json` 与同工作区的另一个进程共享（曾在其中观察到非本次请求产生的
> `evidence-submit-concurrent-real-0` 等记录）。因此所有结论均以**同一批请求内的前后对照**为准，
> 不依赖任何跨批次的绝对计数。

---

## 1. 一句话结论

**有 500，而且有 5 类可稳定复现的触发路径；另外有 1 处严重的越权 + 1 处跨进程数据丢失，必须修。**

按严重度排序的 6 个严重问题：

1. **多进程/多 worker 并发写 `data/repository.json` 会直接 500**（实测失败率 5%–19%），根因是 `_flush()` 使用**固定临时文件名**且无锁；
2. **4 个 POST 接口收到「JSON 但不是对象」的 body（`[1,2,3]` / `"hello"` / `123` / `true`）直接 500**；
3. **`/exercises/{setId}/submit` 与 `/workflows` 的 `autoRun` 路径缺少 answers 元素类型护栏 → 500**（`/run` 上的护栏未覆盖这两处）；
4. **`partner-match` / `proactive` 的嵌套字段类型错误 → 12 类输入可稳定 500**；
5. **完全没有鉴权边界**：不带 token / 假 token 即可读写**任意** userId 的画像与掌握度；未认证的 `POST /api/v1/demo/reset` 会清空**全体用户**的 submissions/evidences/traces/workflows 并**吊销所有会话**（全体用户被强制登出，且原凭据**永久**无法再登录）；
6. **多进程共享同一个 JSON 文件会静默丢数据**（实测：服务 B 注册的用户被服务 A 的下一次写入从文件中抹掉）。

已确认**没有**问题的高危项：SQL/命令注入（无 SQL 拼接、无 shell 调用）、路径穿越（6 类 payload 全部 404，无法读取 `repository.json` 或文件系统）、500 响应体泄漏堆栈或内部路径（统一为 `{errorCode,message,details}`）。

已知并接受的基线行为**全部复现无误**，未被本次排查破坏：
`mastery 42 / profileVersion 1`、`Plan v1 时长 [30,30]`、提交 √√× → `score 66.67 / mastery 42→58 / needReplan true`、
重规划后 `Plan v2 时长 [45,15]`、`workflow trace 3 agent / 3 tool`。

---

## 2. Bug 清单（按严重度排序）

### 复现前置（所有命令通用）

```powershell
# 终端 1：启动服务（保持运行）
cd E:\C4-liantiao\liantiao3\server\zhixue-agent-server
$env:PORT=5211; $env:ZHIXUE_QUIET=1
& E:\C4-liantiao\.venv-lt\Scripts\python.exe run.py --quiet
```

```powershell
# 终端 2：以下所有 curl 命令可直接粘贴（curl.exe 为 Windows 自带）
$H = @("-H","Content-Type: application/json","-H","X-API-Contract-Version: api-contract-v0.3")
curl.exe -s -o NUL -w "%{http_code}`n" http://127.0.0.1:5211/health   # 期望 200
```

---

### 🔴 S1（严重）多进程/多 worker 并发写导致 500 —— `_flush()` 固定临时文件名且无锁

**严重度**：严重（生产部署必然触发：`gunicorn -w N`、多实例、或本工作区这种两个进程同时读写）

**复现命令**（需要两个进程指向同一个 `data/repository.json`，这是默认行为）：

```powershell
# 终端 A、B 各起一个服务（同一份 data/repository.json）
# 终端 A:
cd E:\C4-liantiao\liantiao3\server\zhixue-agent-server; $env:PORT=5211; & E:\C4-liantiao\.venv-lt\Scripts\python.exe run.py --quiet
# 终端 B:
cd E:\C4-liantiao\liantiao3\server\zhixue-agent-server; $env:PORT=5212; & E:\C4-liantiao\.venv-lt\Scripts\python.exe run.py --quiet

# 终端 C：对两个端口同时打 16 个并发写请求
$body = '{"goal":"并发"}'
1..16 | ForEach-Object {
  $port = if ($_ % 2) { 5211 } else { 5212 }
  Start-Job { param($p,$b)
    curl.exe -s -o NUL -w "$p -> %{http_code}`n" -X POST "http://127.0.0.1:$p/api/v1/workflows" `
      -H "Content-Type: application/json" -H "X-API-Contract-Version: api-contract-v0.3" -d $b
  } -ArgumentList $port,$body
} | Wait-Job | Receive-Job
```

**实际响应**（实测 4 轮，每轮 n=8/16/32/64）：

```
双进程并发 n= 8 -> {200: 8}              失败=0  500率=0%
双进程并发 n=16 -> {500: 3, 200: 13}     失败=3  500率=19%
双进程并发 n=32 -> {200: 29, 500: 3}     失败=3  500率=9%
双进程并发 n=64 -> {200: 61, 500: 3}     失败=3  500率=5%
样本 code=500 {"details":null,"errorCode":"INTERNAL_ERROR","message":"internal server error"}
```

**期望响应**：并发写不应产生 500（至少应串行化或返回 409/503 并给出可重试语义）。
成功响应样例：`{"sessionId":"session-xxxx","traceId":"trace-session-xxxx","status":"running","currentStep":"exercise","nextAction":"获取练习题并开始学习"}`

**根因**：`app/repositories/json_repository.py:25-31`

```python
def _flush(self) -> None:
    self.path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = self.path.with_suffix(self.path.suffix + ".tmp")   # ← 固定文件名，进程间共享
    with temporary_path.open("w", encoding="utf-8") as stream:
        json.dump(self._data, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    os.replace(temporary_path, self.path)                                # ← 另一方已把它移走 → 抛异常
```

两个写入方共用 `repository.json.tmp`：A 的 `os.replace` 先把它移走，B 随后 `os.replace` 失败，
异常冒泡到路由 → 500。此外 `save()`（`:37-39`）每次都全量重写整个仓库，既放大了竞态窗口，
也让单次写耗时随文件体积线性增长。

**补充实测（重要，用于界定范围）**：**单进程内**高并发（同一端口 64/128/128 个并发写，累计 320+ 请求）
**未能复现 500**（0 失败、无残留 `.tmp`、文件仍是合法 JSON）。所以该缺陷的触发条件是
**存在第二个写入方**（多 worker / 多实例 / 并行的测试脚本），而不是单进程多线程。

**建议改法**：
1. 临时文件名唯一化：`tempfile.NamedTemporaryFile(dir=self.path.parent, delete=False)`，避免共享 `.tmp`；
2. 进程内加 `threading.RLock`、跨进程用 `filelock`/`portalocker` 或 `msvcrt.locking` 包住「写临时文件 + replace」；
3. 生产化建议换 `SqliteRepository`（仓库里已有 `app/repositories/sqlite_repository.py`，`create_app` 改一行即可），
   或改为带版本号的追加式写入 + 读时合并。

---

### 🔴 S2（严重）body 是「JSON 但非对象」时，4 个 POST 接口直接 500

**严重度**：严重（未鉴权即可打崩接口，且属最常见的客户端误用）

**复现命令**：

```powershell
$H = @("-H","Content-Type: application/json","-H","X-API-Contract-Version: api-contract-v0.3")
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/workflows @H -d "[1,2,3]"
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/workflows/sess-x/run @H -d "[1,2,3]"
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/exercises/set-demo-binary-tree-001/submit @H -d "[1,2,3]"
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/agent/partner-match @H -d "[1,2,3]"
```

**实际响应**（`"hello"` / `123` / `true` 同样触发；`null` 不触发）：

```
HTTP 500
{"details":null,"errorCode":"INTERNAL_ERROR","message":"internal server error"}
```

服务端日志中的根因栈（本次实测抓到）：

```
File "app/api/workflows.py", line 47, in create_workflow
    goal = data.get("goal")
AttributeError: 'int' object has no attribute 'get'          # 'bool' / 'list' / 'str' 同

File "app/api/workflows.py", line 242, in run_workflow_api
    answers = data.get("answers") if isinstance(data.get("answers"), list) else None
AttributeError: 'list' object has no attribute 'get'

File "app/api/exercises.py", line 108, in submit_exercises
    user_id = data.get("userId", "demo-user")
AttributeError: 'list' object has no attribute 'get'

File "app/api/partner_match.py", line 13, in post_partner_match
    user = data.get("user") or {"userId": data.get("userId", "demo-user")}
AttributeError: 'list' object has no attribute 'get'
```

**期望响应**：`400` + `{"errorCode":"BAD_REQUEST","message":"request body must be an object","details":null}`。
**对照**：`/api/v1/agent/proactive` 做对了（`app/api/proactive.py:11-16` 有 `isinstance(data, dict)` 护栏，实测返回 400），
说明这是 4 处遗漏而非设计取舍。

**根因**：
- `app/api/workflows.py:46`（`data = request.get_json(silent=True) or {}`，`[1,2,3]` 为真值直接穿过）
- `app/api/workflows.py:241`
- `app/api/exercises.py:107`
- `app/api/partner_match.py:12`

**建议改法**（4 处统一）：

```python
data = request.get_json(silent=True)
if not isinstance(data, dict):
    return _error("BAD_REQUEST", "request body must be an object", None)
```

---

### 🔴 S3（严重）answers 元素类型护栏只加在 `/run`，`/submit` 与 `autoRun` 路径仍可 500

**严重度**：严重（与已知修复同源，说明护栏收敛不完整）

**复现命令**：

```powershell
$H = @("-H","Content-Type: application/json","-H","X-API-Contract-Version: api-contract-v0.3")

# 3.1 /exercises/{setId}/submit —— answers 元素不是对象
curl.exe -s -w "`n[%{http_code}]`n" -X POST `
  http://127.0.0.1:5211/api/v1/exercises/set-demo-binary-tree-001/submit @H `
  -d '{"userId":"demo-user","idempotencyKey":"k1","answers":["a"]}'

# 3.2 POST /api/v1/workflows 的 autoRun 路径 —— 绕过 /run 的同一护栏
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/workflows @H `
  -d '{"goal":"g","autoRun":true,"answers":["a"]}'

# 3.3 对照：同一份输入打到 /run 是被正确拦截的
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/workflows/<已有sid>/run @H `
  -d '{"answers":["a"]}'
```

**实际响应**：

```
3.1 -> HTTP 500 {"details":null,"errorCode":"INTERNAL_ERROR","message":"internal server error"}
3.2 -> HTTP 500 {"details":null,"errorCode":"INTERNAL_ERROR","message":"internal server error"}
3.3 -> HTTP 400 {"details":{"field":"answers"},"errorCode":"BAD_REQUEST","message":"answers 中每一项都必须是对象"}   OK
```

已实测可 500 的元素形态：`["a"]`、`[1]`、`[None]`、`[[["x"]]]`。

**期望响应**：400，与 3.3 一致。

**根因**：
- `app/tools/assessment_tools.py:23-26`：`exercise_id = answer.get("exerciseId")` 假设元素是 Mapping；
- `app/api/exercises.py:131`：`submit_exercises` **直接**调用 `grade_exercise(...)`，不经过 `ToolRegistry`
  （`app/runtime/tool_registry.py:65-70` 的 `except Exception → ToolError` 在这里不生效），AttributeError 直接冒泡；
- `app/api/workflows.py:71-73`：`create_workflow` 的 `autoRun` 分支直接把 `data["answers"]` 交给
  `_run_saved_workflow`，**跳过了 `:244-267` 那段 `_MAX_ANSWERS` / `isinstance(item, dict)` 护栏**。

**建议改法**：
1. 把 `:244-267` 的护栏抽成 `_validate_answers(answers) -> error | None`，在 `run_workflow_api`、
   `create_workflow`（autoRun 分支）、`submit_exercises` 三处统一调用；
2. `assessment_tools.grade_exercise` 内改为 `if not isinstance(answer, Mapping): continue` 做纵深防御。

---

### 🔴 S4（严重）`partner-match` / `proactive` 嵌套字段类型错误 → 12 类输入可稳定 500

**严重度**：严重（纯输入校验缺失，两个接口都是前端会直接调用的）

**复现命令**：

```powershell
$H = @("-H","Content-Type: application/json","-H","X-API-Contract-Version: api-contract-v0.3")

# 4.1 partner-match：user 的子字段不是对象（4 类）
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/agent/partner-match @H -d '{"user":{"knowledge":"abc"}}'
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/agent/partner-match @H -d '{"user":{"basicInfo":"abc"}}'
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/agent/partner-match @H -d '{"user":{"time":"abc"}}'
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/agent/partner-match @H -d '{"user":{"learningGoal":"abc"}}'
# 4.2 partner-match：candidate 的子字段不是对象（2 类）
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/agent/partner-match @H -d '{"candidates":[{"knowledge":"abc"}]}'
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/agent/partner-match @H -d '{"candidates":[{"basicInfo":1}]}'
# 4.3 proactive：location / now / lastStudyAt 类型错误（3 类）
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/agent/proactive @H -d '{"context":{"location":123}}'
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/agent/proactive @H -d '{"context":{"now":5}}'
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/agent/proactive @H -d '{"context":{"lastStudyAt":5}}'
# 4.4 proactive：daysLeft 可被 float() 解析为 inf/nan（3 类）
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/agent/proactive @H -d '{"context":{"daysLeft":"Infinity"}}'
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/agent/proactive @H -d '{"context":{"daysLeft":"NaN"}}'
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/agent/proactive @H -d '{"context":{"daysLeft":1e400}}'
```

**实际响应**：以上 12 条**全部 HTTP 500**：

```
{"details":null,"errorCode":"INTERNAL_ERROR","message":"internal server error"}
```

服务端日志中的根因栈（本次实测抓到，含精确行号）：

```
agent/partner_match.py:35  value = (profile.get(section) or {}).get(key, [])      AttributeError: 'str' object has no attribute 'get'
agent/partner_match.py:51  basic_score = 10 if (user_info.get("grade") == ...      AttributeError: 'str'/'int' object has no attribute 'get'
agent/partner_match.py:26  left_ranges = _time_ranges((left.get("time") or {}).get("freeTime"))   AttributeError
agent/partner_match.py:42  goal_score = 30 if user_goal.get("course") ...          AttributeError
agent/proactive.py:67      location = (context.get("location") or "unknown").strip()   AttributeError: 'int' object has no attribute 'strip'
agent/proactive.py:22      return datetime.fromisoformat(value.replace("Z", "+00:00"))  AttributeError: 'int' object has no attribute 'replace'
agent/proactive.py:146     f"考试剩 {int(days_left)} 天（紧迫度贡献 ...）"        OverflowError: cannot convert float infinity to integer
                                                                                  ValueError: cannot convert float NaN to integer
```

**期望响应**：400 + `{"errorCode":"BAD_REQUEST", ...}`（契约 `responses.400 → BadRequest/ErrorResponse` 已声明该路径）。

**根因**：
- `app/agent/partner_match.py:26 / 35 / 42 / 51`：`(x or {})` 只能挡 falsy，挡不住 `"abc"` / `1`；
- `app/agent/proactive.py:67`：`(context.get("location") or "unknown").strip()`；
- `app/agent/proactive.py:22`（`_parse_iso8601`）只 `except ValueError`，非字符串输入抛 AttributeError；
- `app/agent/proactive.py:63-66` 的 `_as_float()` 会把 `"Infinity"`/`"NaN"`/`1e400` 成功转成 `inf`/`nan`，
  随后 `:146`（以及 `:174` 的 `int(days_left)`）对 `inf`/`nan` 取整即崩。

**建议改法**：
1. `_as_float` 增加有限性校验：`value = float(v); return value if math.isfinite(value) else default`；
2. `_parse_iso8601` 改为 `if not isinstance(value, str): return None`，并补 `except (ValueError, TypeError)`；
3. `proactive_decision` 顶部对 `location` 做 `isinstance(..., str)` 归一化；
4. `partner_match` 的 `_list` / `_overlap_minutes` / `score_partner` 统一用
   `section if isinstance(section, dict) else {}` 取值；并在 `app/api/partner_match.py` 对
   `user` / `candidates[*]` 的 6 个子字段做类型白名单校验。

---

### 🔴 S5（严重）鉴权边界缺失：任意匿名调用者可读写任意用户数据，且可把全体用户踢下线

**严重度**：严重（访问控制 / 数据完整性 / 可用性三合一）

> 代码注释（`app/__init__.py:44-59`）声明「鉴权是可选的，不是门禁」是**有意取舍**。
> 但该取舍的实际后果比注释描述的严重得多——不只是"能读演示数据"，而是"能改任何人的学习记录、
> 能让所有人掉线"。以下给出可复现证据。

**复现命令**：

```powershell
$H = @("-H","Content-Type: application/json","-H","X-API-Contract-Version: api-contract-v0.3")

# 5.1 注册两个真实用户
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/auth/register @H -d '{"nickname":"甲","grade":"大二"}'
# 记下 userId=U1, token=T1
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/auth/register @H -d '{"nickname":"乙","grade":"大三"}'
# 记下 userId=U2

# 5.2 越权读：不带 token / 带假 token / 带甲的真 token —— 三种方式都能读到乙的完整画像
curl.exe -s http://127.0.0.1:5211/api/v1/profile/U2
curl.exe -s http://127.0.0.1:5211/api/v1/profile/U2 -H "Authorization: Bearer bogus"
curl.exe -s http://127.0.0.1:5211/api/v1/profile/U2 -H "Authorization: Bearer T1"

# 5.3 越权写：甲拿着自己的合法 token，把 userId 填成乙 → 直接改乙的掌握度
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/exercises/set-demo-binary-tree-001/submit `
  -H "Content-Type: application/json" -H "X-API-Contract-Version: api-contract-v0.3" `
  -H "Authorization: Bearer T1" `
  -d '{"userId":"U2","idempotencyKey":"cross-1","answers":[{"exerciseId":"exercise-preorder-001","answer":"A"},{"exerciseId":"exercise-inorder-001","answer":"B"},{"exerciseId":"exercise-postorder-001","answer":"A"}]}'

# 5.4 未认证清库 + 全员强制登出
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/demo/reset @H -d '{}'
curl.exe -s -w "`n[%{http_code}]`n" http://127.0.0.1:5211/api/v1/auth/me -H "Authorization: Bearer T1"
curl.exe -s -w "`n[%{http_code}]`n" -X POST http://127.0.0.1:5211/api/v1/auth/login @H -d '{"userId":"U1","token":"T1"}'
```

**实际响应**（本次实测原文）：

```
5.2  甲(带token) 读乙画像  HTTP 200  userId=u-81093f57b23b mastery=0
     无 token 读乙画像     HTTP 200  userId=u-81093f57b23b mastery=0
     无效 token 读乙画像   HTTP 200  userId=u-81093f57b23b mastery=0

5.3  甲(带token) 用 userId=乙 提交 -> HTTP 200
     masteryUpdate={'knowledgePointId': 'binary-tree-postorder', 'newScore': 16, 'oldScore': 0}
     乙提交前 mastery=0 version=1  ->  乙提交后 mastery=16 version=2
     甲自己的 mastery 仍为 0 version=1        <- 数据被写到了别人身上

5.4  注册 -> u-266341a6f3ca
     reset 前 GET /api/v1/auth/me            -> 200
     reset 前 sessions 条数 = 2
     未认证 POST /api/v1/demo/reset          -> 200        <- 无任何凭据
     reset 后 sessions 条数 = 0 | users 条数 = 21
     reset 后 GET /api/v1/auth/me            -> 401 {"errorCode":"UNAUTHORIZED","message":"登录已失效，请重新登录"}
     reset 后 login(本地保存的凭据)           -> 401 {"errorCode":"UNAUTHORIZED","message":"登录已失效，请重新登录"}
     该用户仍在 users 中 = True，profile 仍在 = True        <- 但已永久无法登录
```

**期望响应**：
- 5.2：携带 U2 之外身份的请求应 `403`（或至少 `404`）；
- 5.3：`userId` 必须取自凭据（`g.current_user`），请求体里的 `userId` 只能被忽略或校验一致，否则 `403`；
- 5.4：`demo/reset` 应要求凭据，且**只清 demo-user 的数据**、**不得清除 `sessions`**。

**根因**：
- `app/__init__.py:44-67`：`resolve_optional_identity` 把无 token / 无效 token 一律降级为游客，**不做拦截**；
- `app/api/profile.py:15-22`：`get_profile` 只按路径参数查库，从不比对 `g.current_user`；
- `app/api/exercises.py:108`：`user_id = data.get("userId", "demo-user")` —— 身份完全由调用方声明；
- `app/api/demo.py:79-81`：`for collection in ("traces","submissions","evidences","plan_histories","workflows","sessions")` ——
  **全局清空**（含 `sessions`），而 `profiles` / `plans` 不清 → 既跨租户删数据，又造成悬空引用；
- `app/auth/service.py:293-302` + `app/api/auth.py:104-108`：`login` 只认 `sessions` 里的 token，
  session 被清后即使用户记录还在也**无法恢复登录**，而 `register` 只会发新 userId → 旧画像/计划成为孤儿数据。

**建议改法**（最小改动顺序）：
1. 把 `sessions` 从 `demo/reset` 的清理列表中移除（`app/api/demo.py:79-81`）；
2. `demo/reset` 加环境变量开关或 Bearer 校验（生产默认关闭）；
3. `submit_exercises` / `create_workflow`：若 `g.current_user` 存在则强制 `user_id = g.current_user["userId"]`，
   否则回退 `demo-user`；请求体 `userId` 与之不符 → `403`；
4. `get_profile` / `get_current_plan` / `get_plan_diff` 等读接口加同样的归属校验；
5. 生产化路径见仓库自己的文档 `docs/02 §2.2`（代码注释已给出迁移方向）。

---

### 🔴 S6（严重）多进程共享 JSON 文件 → 静默丢数据（无锁 / 无 reload / 全量覆盖）

**严重度**：严重（多 worker 部署下是**无声的数据损坏**，比 500 更难发现）

**复现命令**：同 S1 的双服务启动方式，然后：

```powershell
$H = @("-H","Content-Type: application/json","-H","X-API-Contract-Version: api-contract-v0.3")
# A=5211, B=5212
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/auth/register @H -d '{"nickname":"用户A","grade":"大二"}'
curl.exe -s -X POST http://127.0.0.1:5212/api/v1/auth/register @H -d '{"nickname":"用户B","grade":"大三"}'
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/auth/register @H -d '{"nickname":"用户C","grade":"大四"}'
# 读取 data/repository.json 的 users 键，观察"用户B"是否还在
```

**实际响应**（本次实测原文，用户 B = `u-3c0f99309b0b`）：

```
服务A 注册 用户A -> u-5884497feef1        文件 users: [... 含 A ...]
服务B 注册 用户B -> u-3c0f99309b0b        文件 users: [... 含 B ...]
服务A 再注册 用户C -> u-82c0e4cc5d9b      文件 users: [... 含 C, 不含 B ...]
用户B 是否被覆盖丢失: True

服务A 用 用户B 凭据登录 -> 401 {"errorCode":"UNAUTHORIZED","message":"账号不存在或已注销，请重新注册"}
服务B 用 用户B 凭据登录 -> 200 {...}      <- 只有写它的那个进程还记得
服务A 读 用户B 画像     -> 404 {"errorCode":"NOT_FOUND","message":"profile not found"}
服务B 读 用户B 画像     -> 200
```

**期望响应**：任一进程都能读到完整数据；或写入时检测到文件已被他人修改并拒绝/重试，而不是静默覆盖。

**根因**：`app/repositories/json_repository.py:17-23`（`_load` 只在 `__init__` 执行一次，之后永不 reload）
+ `:37-39`（`save` 直接改内存并 `_flush`）
+ `:25-31`（`_flush` 用内存快照**全量重写**整个文件）。
进程 A 的快照里没有 B 写的记录，A 的任何一次 save 都会把文件回退到"A 的视角"。

**建议改法**：
1. `save()` 前比对文件 `mtime`/内容哈希，发现外部修改则先 `_load()` 合并（乐观并发）；
2. 或直接切换到 `SqliteRepository`（已在仓库内实现，`create_app` 一行改动）；
3. 若坚持 JSON：按集合拆分成多个文件 + 文件锁，避免"任一写入重写全库"。

---

### 🟠 M1（中等）`maxSteps=1` 时，已成功判分的流程被改判为 `error` / `max_steps`

**严重度**：中等（状态机语义错误，前端会展示"流程失败"）

**复现命令**：

```powershell
$H = @("-H","Content-Type: application/json","-H","X-API-Contract-Version: api-contract-v0.3")
$sid = (curl.exe -s -X POST http://127.0.0.1:5211/api/v1/workflows @H -d '{"goal":"g","maxSteps":1}' | ConvertFrom-Json).sessionId
curl.exe -s -X POST "http://127.0.0.1:5211/api/v1/workflows/$sid/run" @H -d '{}'
curl.exe -s -X POST "http://127.0.0.1:5211/api/v1/workflows/$sid/run" @H `
  -d '{"answers":[{"exerciseId":"exercise-preorder-001","answer":"A"},{"exerciseId":"exercise-inorder-001","answer":"B"},{"exerciseId":"exercise-postorder-001","answer":"A"}]}'
```

**实际响应 vs 期望**：

| maxSteps | 实测 run2(带答案) 结果 | 期望 |
| --- | --- | --- |
| 1 | `status=error`、`currentAgent=max_steps`、`finalAction='已达到工作流步数上限'`，但 `score=66.67` 已判分并落库 | `status=completed` / `currentAgent=finish` |
| 2 | `status=completed`、`currentAgent=finish` | OK |
| 3 | `status=completed`、`currentAgent=finish` | OK |

**根因**：`app/runtime/loop.py:15` 的 `for _ in range(session.max_steps):` 搭配 `:58-65` 的 `else:` 子句。
循环体在 `session.advance("assessment", ...)`（`:51`）后**没有 `break`**，当 `range` 恰好用尽时
Python 会执行 `for...else`，于是把刚判完分、本应继续走到 `finish` 的会话强行 `advance("max_steps", ..., "error", ...)`。
另注：`currentAgent` 落成 `"max_steps"`，这不是任何已声明的 agent 名。

**建议改法**：把"步数用尽"改为显式判断而非循环 `else`，例如
`if session.status == "running" and session.current_step != "finish": session.advance("max_steps", ...)`。

---

### 🟠 M2（中等）已完成的工作流再提交答案：静默 200、不判分，却把 `pendingSubmission=true` 落库

**严重度**：中等（提交被静默吞掉 + 会话状态自相矛盾）

**复现命令**：

```powershell
$H = @("-H","Content-Type: application/json","-H","X-API-Contract-Version: api-contract-v0.3")
$sid = (curl.exe -s -X POST http://127.0.0.1:5211/api/v1/workflows @H -d '{"goal":"g"}' | ConvertFrom-Json).sessionId
curl.exe -s -X POST "http://127.0.0.1:5211/api/v1/workflows/$sid/run" @H -d '{}'
curl.exe -s -X POST "http://127.0.0.1:5211/api/v1/workflows/$sid/run" @H -d '{"answers":[{"exerciseId":"exercise-preorder-001","answer":"A"},{"exerciseId":"exercise-inorder-001","answer":"B"},{"exerciseId":"exercise-postorder-001","answer":"A"}]}'
# 已完成（status=completed）后再提交一次
curl.exe -s -X POST "http://127.0.0.1:5211/api/v1/workflows/$sid/run" @H -d '{"answers":[{"exerciseId":"exercise-preorder-001","answer":"D"}]}'
curl.exe -s http://127.0.0.1:5211/api/v1/workflows/$sid
```

**实际响应**：

```
run4(再提交) -> HTTP 200
  status=completed  currentAgent=finish  stateVersion=4（未变）
  state.pendingSubmission = true          <- 被写进持久化状态
GET /api/v1/workflows/<sid> -> 200 {"status":"completed","currentAgent":"finish","stateVersion":4,"finalAction":"学习流程已完成"}
```

**期望响应**：`409 CONFLICT`（`ErrorResponse.errorCode` 枚举里已有 `CONFLICT`），或至少不修改已完成会话的状态。

**根因**：`app/api/workflows.py:212-214` 无条件 `state.update({..., "pendingSubmission": True, "awaitingAnswers": False})`；
随后 `app/runtime/loop.py:16-17` 因 `session.status != "running"` 立即 `break`，所以状态被改而流程没走；
`:231-234` 又把这份被改坏的状态 `save` 回仓库。

**建议改法**：`_run_saved_workflow` 开头（`:196` 附近）加：

```python
if workflow.get("status") != "running" and has_new_input:
    return _error("CONFLICT", "workflow already completed", {"sessionId": session_id}, 409)
```

---

### 🟠 M3（中等）空 answers / 全未知 exerciseId 也判 0 分并写 history → 画像自相矛盾

**严重度**：中等（审计数据不一致；前端若用 history 画掌握度曲线会展示错误数值）

**复现命令**：

```powershell
$H = @("-H","Content-Type: application/json","-H","X-API-Contract-Version: api-contract-v0.3")
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/demo/reset @H -d '{}' | Out-Null
$sid = (curl.exe -s -X POST http://127.0.0.1:5211/api/v1/workflows @H -d '{"goal":"g"}' | ConvertFrom-Json).sessionId
curl.exe -s -X POST "http://127.0.0.1:5211/api/v1/workflows/$sid/run" @H -d '{}' | Out-Null
curl.exe -s -X POST "http://127.0.0.1:5211/api/v1/workflows/$sid/run" @H -d '{"answers":[]}'
curl.exe -s http://127.0.0.1:5211/api/v1/profile/demo-user
```

**实际响应**：

```
mastery 数组      = [('binary-tree-postorder', 42)]      <- 实际掌握度仍是 42
profileVersion    = 2                                     <- 被 +1
history           = [{"oldScore":42,"newScore":38,"source":"assessment",
                      "evidenceIds":["evidence-session-..."],"timestamp":"..."}]
evidence          = [{"id":"evidence-session-...","knowledgePointId":"unknown",
                      "metric":"accuracy","value":0.0,...}]
```

即：**history 说掌握度从 42 掉到 38，mastery 数组却说还是 42**；同时凭空写入一条
`knowledgePointId="unknown"` 的证据。同一现象也出现在
`answers=[{"exerciseId":"no-such-exercise","answer":"A"}]`（未知题号）与 `answers=[{}]` 上。

**期望响应**：空 answers / 无任何有效题号时应 `400`（"至少要有一道有效作答"），
不应写 history、不应 +profileVersion、不应写 evidence。

**根因**：
- `app/tools/assessment_tools.py:28-30`：`valid_ids` 为空时 `score = round(0 / max(1, 0) * 100, 2) = 0.0`（不报错）；
- `app/tools/assessment_tools.py:35`：`accuracy = {}`；
- `app/tools/assessment_tools.py:73-81`：`persist_mastery` **无条件** `profile_model.advance_version()` 并追加
  `MasteryHistory(old, suggested_new)`；而 `:73-76` 的 mastery 更新循环遍历 `per_knowledge_accuracy`，
  空字典 → **一个知识点都不更新**。于是"版本涨了、历史记了、掌握度没动"。
- `app/api/workflows.py:163`：`next(iter(assessment.per_knowledge_accuracy), "unknown")` 在空字典时得到 `"unknown"`
  并以它作为重规划目标知识点。

**建议改法**：
1. `run_workflow_api` / `submit_exercises` 在 `answers` 为空、或过滤后命中 `answer_keys` 数为 0 时返回
   `400 BAD_REQUEST`（`details: {"field":"answers"}`）；
2. `persist_mastery` 在 `per_knowledge_accuracy` 为空时直接 `return None`，不写 version/history/evidence。

---

### 🟠 M4（中等）`idempotencyKey` / `goal` / chat `message` 无长度上限 → 仓库与响应体积爆炸

**严重度**：中等（一个请求即可把仓库放大到几十 MB，此后每次 save 都全量重写）

**复现命令**：

```powershell
$H = @("-H","Content-Type: application/json","-H","X-API-Contract-Version: api-contract-v0.3")
# 4.1：20 万字符的 idempotencyKey（会被拼进 submissionId 与 traceId，双份落库）
$key = "K" * 200000
curl.exe -s -o NUL -w "%{size_download} bytes`n" -X POST `
  http://127.0.0.1:5211/api/v1/exercises/set-demo-binary-tree-001/submit @H `
  -d "{`"userId`":`"demo-user`",`"idempotencyKey`":`"$key`",`"answers`":[{`"exerciseId`":`"exercise-preorder-001`",`"answer`":`"A`"}]}"
(Get-Item E:\C4-liantiao\liantiao3\server\zhixue-agent-server\data\repository.json).Length

# 4.2：100 万字符的 goal
$g = "G" * 1000000
curl.exe -s -o NUL -w "%{http_code}`n" -X POST http://127.0.0.1:5211/api/v1/workflows @H -d "{`"goal`":`"$g`"}"

# 4.3：100 万字符的聊天消息（写入 chat/history.json）
$m = "M" * 1000000
curl.exe -s -o NUL -w "%{http_code}`n" -X POST http://127.0.0.1:5211/api/agent/chat @H -d "{`"message`":`"$m`"}"
curl.exe -s -o NUL -w "history=%{size_download} bytes`n" http://127.0.0.1:5211/api/agent/history
```

**实际响应**：

```
4.1 idempotencyKey 20万字符 -> HTTP 200  resp_len=800,492 bytes
    submissionId 长度 = 200,035   traceId 长度 = 200,013
    repository.json  31,927 -> 2,826,331 bytes（单请求 +2.8MB）
    压力测试中继续放大到 53,580,911 bytes（53MB），此后 64 并发写耗时 56–65 秒
4.2 goal 100万字符          -> HTTP 200（响应仅 196 字节，但 goal 全量落 workflows 集合）
4.3 chat message 100万字符  -> HTTP 200
    chat/history.json       1,004,751 bytes；GET /api/agent/history 响应 1,007,523 bytes
对照：chat image 5,000,001 字符 -> HTTP 400 {"errorCode":"BAD_REQUEST","message":"image 必须是字符串且不超过 5MB"}  OK
```

**期望响应**：与 `answers` 护栏一致 —— 超长输入返回 `400 BAD_REQUEST` 并给出 `details.limit`。
`image` 已有 5MB 上限（`app/api/chat.py:26,105-110`），说明项目已有此模式，只是未覆盖其余字段。

**根因**：
- `app/api/exercises.py:109-116`：`idempotencyKey` 只校验「非空字符串」，无长度上限，且被拼进
  `result_id`（`:116`）、`trace_id`（`:146`）、`evidence_id`（`:147`），三处落库；
- `app/api/workflows.py:47-49`：`goal` 只校验非空；
- `app/api/chat.py:102-110`：只对 `image` 限长，`message` 无限长；`chat_llm` 把消息追加进 `chat/history.json`。

**建议改法**：
1. 统一常量化上限：`idempotencyKey ≤ 128`、`goal ≤ 512`、`message ≤ 8000`、`sessionId ≤ 128`、
   `userId ≤ 64`，超限返回 `400` 并带 `details: {field, limit, received}`；
2. `chat/history.json` 增加条数上限与单条长度上限（例如各 200 条 / 8KB）并定期截断。

---

### 🟠 M5（中等）`demo/reset` 破坏幂等语义：同 key 重放会二次累加掌握度，并留下悬空引用

**严重度**：中等（幂等键的核心承诺被破坏）

**复现命令**：

```powershell
$H = @("-H","Content-Type: application/json","-H","X-API-Contract-Version: api-contract-v0.3")
$ans = '{"userId":"demo-user","idempotencyKey":"dangling-1","answers":[{"exerciseId":"exercise-preorder-001","answer":"A"},{"exerciseId":"exercise-inorder-001","answer":"B"},{"exerciseId":"exercise-postorder-001","answer":"A"}]}'
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/demo/reset @H -d '{}' | Out-Null
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/exercises/set-demo-binary-tree-001/submit @H -d $ans
curl.exe -s http://127.0.0.1:5211/api/v1/experiments/snapshot     # evidenceCount=1 submissionCount=1
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/demo/reset @H -d '{}' | Out-Null
curl.exe -s http://127.0.0.1:5211/api/v1/experiments/snapshot     # evidenceCount=0 submissionCount=0
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/exercises/set-demo-binary-tree-001/submit @H -d $ans
curl.exe -s http://127.0.0.1:5211/api/v1/profile/demo-user
```

**实际响应**：

```
提交后：profile.evidence ids = ['evidence-submit-dangling-1']；mastery=58；version=2
reset 前 snapshot: evidenceCount=1 submissionCount=1
reset 后 snapshot: evidenceCount=0 submissionCount=0
reset 后同 key 重放 -> HTTP 200，mastery 42->58 再次生效，version=2，history_len=1
```

**期望响应**：`demo/reset` 要么不动 `submissions`（保留幂等缓存），要么连 `profiles` 一起重置；
不应出现"证据被删、画像仍引用它"和"同一幂等键二次计分"。

**根因**：`app/api/demo.py:79-81` 清了 `submissions` / `evidences` / `traces` / `plan_histories` / `workflows` / `sessions`，
但**不清 `profiles` / `plans`**，同时把 demo-user 画像重写回 baseline。于是
(a) `profiles.history[].evidenceIds` 与 `profiles.evidence[].id` 指向已删除的 `evidences`；
(b) `app/api/exercises.py:117-120` 的幂等短路因 `submissions` 被清而失效，同一 key 被当成新提交。

**建议改法**：`demo/reset` 一并清理 demo-user 画像中的 `history` / `evidence` 字段，
并在响应里明确"本次重置会失效所有幂等键"；或保留 `submissions` 只重置画像以外的部分。

---

### 🟠 M6（中等）掌握度已 100 仍持续触发重规划，plan 版本无意义递增；`plan_histories` 只保留最后一次

**严重度**：中等（决策语义失真 + 版本号不可信）

**复现命令**：

```powershell
$H = @("-H","Content-Type: application/json","-H","X-API-Contract-Version: api-contract-v0.3")
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/demo/reset @H -d '{}' | Out-Null
1..4 | ForEach-Object {
  $b = "{`"userId`":`"demo-user`",`"idempotencyKey`":`"repeat-$_`",`"answers`":[{`"exerciseId`":`"exercise-preorder-001`",`"answer`":`"A`"},{`"exerciseId`":`"exercise-inorder-001`",`"answer`":`"B`"},{`"exerciseId`":`"exercise-postorder-001`",`"answer`":`"A`"}]}"
  curl.exe -s -X POST http://127.0.0.1:5211/api/v1/exercises/set-demo-binary-tree-001/submit @H -d $b |
    ConvertFrom-Json | Select-Object @{n='mastery';e={$_.masteryUpdate.newScore}}, needReplan, @{n='planVer';e={$_.plan.version}}
}
curl.exe -s http://127.0.0.1:5211/api/v1/experiments/snapshot   # 看 summary.planDiffCount
```

**实际响应**：

```
第1次提交 score=66.67 mastery=42->58  needReplan=True planVersion=2
第2次提交 score=66.67 mastery=58->74  needReplan=True planVersion=3
第3次提交 score=66.67 mastery=74->90  needReplan=True planVersion=4
第4次提交 score=66.67 mastery=90->100 needReplan=True planVersion=5
plans/current version = 5  durations = [45, 15]        <- 从 v2 起内容再未变化
diff = {"oldVersion":4,"newVersion":5,"adjustmentReason":"掌握度低于阈值"}
snapshot planDiffCount = 1                              <- 4 次重规划后只剩 1 条
```

**期望响应**：掌握度 100（或计划内容零变化）时 `needReplan=false`、版本不递增；
若确实重规划，`changedTasks` 应为空并明确标注 `no-op replan`。

**根因**：
- `app/tools/plan_tools.py:14-22`：`should_replan` 的 `repeated_error` 判据是 `state.get("repeatedError", False)`，
  而调用方（`app/api/exercises.py:143`）传的是 `score < 80`，与原掌握度无关 → **只要本次得分 < 80 就永远重规划**；
- `app/tools/plan_tools.py:43-45`：`replan_learning_path` 无条件 `version + 1`，即使 `changed` 为空；
- `app/api/exercises.py:169` 与 `app/api/workflows.py:185`：`plan_histories` 以 `planId` 为键保存 →
  每次覆盖，所谓"历史"其实只有最后一条（`experiments.py:53,96` 的 `planDiffCount` 因此恒为 1）。

**建议改法**：
1. `should_replan` 增加 `mastery >= 85 → 不重规划`；`repeatedError` 改为"同一知识点连续 2 次答错"而非"本次 < 80"；
2. `replan_learning_path` 在 `changed` 为空时保持 `version` 不变；
3. `plan_histories` 改为以 `f"{planId}:v{newVersion}"` 为键（保留全部版本），`plans/{id}/diff` 取最新版本。

---

### 🟠 M7（中等）响应字段类型不符契约（int / null 原样回显），并伴随"创建成功却立刻 404"

**严重度**：中等（前端按 string 解析会得到 `undefined`；且状态不一致）

**复现命令**：

```powershell
$H = @("-H","Content-Type: application/json","-H","X-API-Contract-Version: api-contract-v0.3")
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/workflows @H -d '{"goal":"g","sessionId":424242}'
curl.exe -s -w "`n[%{http_code}]`n" http://127.0.0.1:5211/api/v1/workflows/424242
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/agent/proactive @H -d '{"userId":123,"context":{}}'
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/agent/proactive @H -d '{"userId":null,"context":{}}'
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/agent/partner-match @H -d '{"user":{"userId":null}}'
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/agent/partner-match @H -d '{"user":{"userId":[1,2]}}'
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/workflows @H -d '{"goal":"g","userId":["a"]}'
```

**实际响应 vs 契约**：

| 请求 | 实测响应 | 契约声明 | 问题 |
| --- | --- | --- | --- |
| `{"sessionId":424242}` | `"sessionId":424242`（integer） | `WorkflowResponse.sessionId: string` | 类型不符 |
| 随后 `GET /workflows/424242` | **404 `workflow not found`** | 刚返回 200 创建成功 | 内存键是 int、文件键是 `"424242"`，同进程永远查不到 |
| `{"userId":123}` (proactive) | `"userId":123` | `ProactiveResponse.userId: string` | 类型不符 |
| `{"userId":null}` (proactive) | `"userId":null` | `string`，非 nullable | nullable 声明与实际不符 |
| `{"user":{"userId":null}}` (partner) | `"userId":null` | 同上 | 同上 |
| `{"user":{"userId":[1,2]}}` (partner) | `"userId":[1,2]` | 同上 | 类型不符 |
| `{"userId":["a"]}` (workflows) | **HTTP 500**（list 被当成 dict key） | 400 | 见 S2 同类 |

**根因**：
- `app/api/workflows.py:54-56`：`session_id = data.get("sessionId") or f"session-..."`，无类型校验；
  `app/repositories/json_repository.py:38` 用 int 作内存键，而 `json.dump`（`:29`）会把 int 键写成字符串 →
  内存与磁盘键类型永久分叉；
- `app/api/workflows.py:55`：`user_id = data.get("userId", "demo-user")`，无类型校验 →
  `app/api/workflows.py:37` → `json_repository.py:34` 抛 `TypeError: unhashable type: 'list'`；
- `app/agent/proactive.py:47`：`user_id = payload.get("userId", "demo-user")` 原样返回；
- `app/agent/partner_match.py:65`：`user.get("userId", "demo-user")` 原样返回。

**建议改法**：在 4 个入口统一做
`if not isinstance(x, str) or not x.strip() or len(x) > 128: return _error("BAD_REQUEST", ...)`；
`JsonRepository` 内部把 `item_id` 强制 `str()` 化，从根上消除 int/str 键分叉。

---

### 🟠 M8（中等）405 / 414 返回 HTML，破坏 `{errorCode,message,details}` 错误契约

**严重度**：中等（前端统一错误处理会解析失败）

**复现命令**：

```powershell
curl.exe -s -i http://127.0.0.1:5211/api/v1/workflows            # GET 一个只支持 POST 的路由
curl.exe -s -i -X PUT http://127.0.0.1:5211/api/v1/demo/reset
curl.exe -s -i "http://127.0.0.1:5211/api/v1/profile/$(('z' * 100000))"
```

**实际响应**：

```
405 -> content-type: text/html; charset=utf-8
       <!doctype html><html lang=en><title>405 Method Not Allowed</title><h1>Method Not Allowed</h1>...
414 -> content-type: text/html;charset=utf-8   （同样非 JSON）
对照 404 -> content-type: application/json
       {"details":null,"errorCode":"NOT_FOUND","message":"resource not found"}   OK
```

**期望响应**：所有错误统一为 `{"errorCode": "...", "message": "...", "details": null}`。

**根因**：`app/__init__.py:115-125` 只注册了 `404` / `400` / `500` 三个 `errorhandler`，
未覆盖 `405`（MethodNotAllowed）、`414`（RequestURITooLarge）、`413`（RequestEntityTooLarge）。

**建议改法**：

```python
from werkzeug.exceptions import HTTPException

@app.errorhandler(HTTPException)
def handle_http_error(error):
    code = {400: "BAD_REQUEST", 401: "UNAUTHORIZED", 404: "NOT_FOUND",
            405: "BAD_REQUEST", 409: "CONFLICT", 413: "BAD_REQUEST",
            414: "BAD_REQUEST"}.get(error.code, "INTERNAL_ERROR")
    return {"errorCode": code, "message": error.description, "details": None}, error.code
```

---

### 🟡 L1（低）`count` 参数在 demo 题集路径被静默忽略

**复现命令**：

```powershell
curl.exe -s "http://127.0.0.1:5211/api/v1/exercises/set-demo-binary-tree-001?count=1"      | ConvertFrom-Json | % { $_.exercises.Count }
curl.exe -s "http://127.0.0.1:5211/api/v1/exercises/set-demo-binary-tree-001?count=999999" | ConvertFrom-Json | % { $_.exercises.Count }
curl.exe -s "http://127.0.0.1:5211/api/v1/exercises/set-demo-binary-tree-001?difficulty=easy&count=1" | ConvertFrom-Json | % { $_.exercises.Count }
```

**实际响应**：`count=1` → **3 道**；`count=999999` → **3 道**；带 `difficulty=easy&count=1` → **1 道**。
**期望**：`count=1` 应返回 1 道（或明确文档化为"demo 固定 3 道"）。
**根因**：`app/api/exercises.py:98-99` 的短路分支在
`set_id == DEMO_EXERCISE_SET_ID and not knowledge_point_id and not difficulty and not excluded_ids`
时直接返回模块级常量 `_DEMO_EXERCISES`（固定 3 道），**完全绕过 `count`**。
**建议**：短路分支也套用 `count`（`_DEMO_EXERCISES[:count]`），或在响应中回显 `count` 的实际生效值。

---

### 🟡 L2（低）同 `sessionId` 重复 create：静默忽略新 goal，且忽略 `autoRun`

**复现命令**：

```powershell
$H = @("-H","Content-Type: application/json","-H","X-API-Contract-Version: api-contract-v0.3")
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/workflows @H -d '{"goal":"目标一","sessionId":"fixed-1"}'
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/workflows @H -d '{"goal":"目标二","sessionId":"fixed-1"}'
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/workflows @H -d '{"goal":"目标三","sessionId":"fixed-1","autoRun":true}'
curl.exe -s http://127.0.0.1:5211/api/v1/workflows/fixed-1      # stateVersion 仍为 1，流程没有推进
```

**实际响应**：三次都返回同一份
`{"sessionId":"fixed-1","traceId":"trace-fixed-1","status":"running","currentStep":"exercise","nextAction":"获取练习题并开始学习"}`；
第三次带 `autoRun:true` 也**没有执行任何步骤**（`GET` 显示 `stateVersion=1`）。
**期望**：客户端超时重试 `create + autoRun` 时应真正推进流程，或返回 `409 CONFLICT` 让客户端显式改调 `/run`。
**根因**：`app/api/workflows.py:56-60` 的已存在短路 `return` 发生在 `autoRun` 处理（`:70-73`）之前。
**建议**：短路分支补上 `if data.get("autoRun") is True: return run_workflow_api(session_id)`，
或在响应中带 `"replayed": true` 让客户端可区分。

---

### 🟡 L3（低）契约缺失 5 条真实存在的路由

**复现命令**：

```powershell
curl.exe -s -o NUL -w "health=%{http_code}`n"      http://127.0.0.1:5211/health
curl.exe -s -o NUL -w "root=%{http_code}`n"        http://127.0.0.1:5211/
curl.exe -s -o NUL -w "agenthealth=%{http_code}`n" http://127.0.0.1:5211/api/agent/health
curl.exe -s -o NUL -w "history=%{http_code}`n"     http://127.0.0.1:5211/api/agent/history
curl.exe -s -o NUL -w "userdata=%{http_code}`n"    http://127.0.0.1:5211/api/agent/user-data
```

**实际响应**：全部 `200`。
**契约实际声明**（用 Python 解析 `openapi.json` 得到，非 PowerShell 推断）：`paths` 共 19 条，
**不含** `/health`、`/`、`/api/agent/health`、`/api/agent/history`（GET/DELETE）、`/api/agent/user-data`。
而 `app/api/chat.py:69-82` 的注释明确说 `/api/agent/health` 是"前端 API 环境页的连通性探针"，
即**前端会调用契约未覆盖的接口**。
**建议**：把 5 条路由补进 `openapi.json`（health 类接口至少声明 `200 → {status}`）。

---

### 🟡 L4（低）`/api/v1/agent/proactive` 请求体校验弱于契约

**复现命令**：

```powershell
curl.exe -s -X POST http://127.0.0.1:5211/api/v1/agent/proactive `
  -H "Content-Type: application/json" -H "X-API-Contract-Version: api-contract-v0.3" -d '{}'
```

**实际响应**：`200` + 一份完整默认决策（`shouldNotify=false`，`userId="demo-user"`）。
**契约**：`ProactiveRequest.required = ["userId","context"]`，`requestBody.required = true`；`ProactiveResponse.userId: string`。
**影响**：缺 `userId` 时响应里的 `userId` 落到默认 `"demo-user"`，前端可能把"别人的"userId 写进本地状态。
**建议**：缺 `userId`/`context` 返回 `400 VALIDATION_ERROR`（或把两者在契约里改为可选并说明默认值）。

---

### 🟡 L5（低）死代码 / 不可达路径

| # | 位置 | 说明（已用 grep 全仓确认引用点） |
| --- | --- | --- |
| 1 | `app/agents/secretary.py`（整文件） | `app/api/workflows.py:113` 每次调用都 `SecretaryAgent()` 塞进 `agents` dict，但 `_agent_action`（`:112-143`）只处理 `diagnosis/planner/exercise/assessment`，而 `finish` 在 `app/runtime/loop.py:23-30` 就被拦下；`decide_next_step` 也从不返回 `"secretary"` → **该实例永远不被调用**（仅 `tests/test_domain_models.py:639` 直接调用它） |
| 2 | `app/tools/profile_tools.py` | `get_mastery` / `profile_summary` 仅被 `tests/test_domain_models.py` 引用，运行时零调用 |
| 3 | `app/tools/course_tools.py` | `select_courses` 仅被测试引用，运行时零调用 |
| 4 | `app/repositories/sqlite_repository.py` | `create_app` 从不使用；仅测试引用 |
| 5 | `app/tools/trace_tools.py:25-27` | `EventStore.list` 仅被测试引用 |
| 6 | `app/runtime/tool_registry.py:22-23` | `ToolError.to_dict` 无调用点（各 `_error` 自行拼 dict） |
| 7 | `app/api/workflows.py:39-40` | `_next_step` 的 `planner` 分支实际不可达：`ensure_demo_data()`（`app/api/demo.py:29-37`）与 `demo/reset`（`:82-86`）都保证 `plans` 非空，且 `demo/reset` 不清 `plans`。仅在手工把 `repository.json` 的 `plans` 清空且 `profiles.demo-user` 仍存在时才可能进入 |
| 8 | `app/api/exercises.py:22-62` | 内联的 `_EXERCISE_BANK` 字面量是**死数据**：`:64-69` 在 `data/question_bank.json` 存在且 ≥30 条、id 唯一时整体覆盖它。实测题库 30 条、id 唯一、30 条均带 `answerKey` → 已切换 |
| 9 | `app/api/demo.py:70-71` | `_repository is None → 500` 分支不可达：`create_app` 必然先 `configure_demo_repository()` |

**建议**：删除 1/2/3/6/8/9；4 与 5 若作为"可替换实现"保留，请在 README 标注"当前运行时未启用"。

---

### 🟡 L6（低）CORS 反射任意 Origin

**复现命令**：

```powershell
curl.exe -s -D - -o NUL -H "Origin: https://evil.example.com" http://127.0.0.1:5211/api/v1/profile/demo-user
```

**实际响应**：`Access-Control-Allow-Origin: https://evil.example.com`（无 `Origin` 时为 `*`）；`Access-Control-Allow-Credentials` 未设置。
**影响**：无 Cookie 凭据，因此不构成经典的凭据窃取；但结合 S5（无鉴权的写接口），
任意网页都能用访客身份跨站读写该服务的 `demo-user` 数据。
**根因**：`app/__init__.py:25` `CORS(app)` 未限定 `origins`。
**建议**：`CORS(app, resources={r"/api/*": {"origins": [...]}})` 白名单化；演示环境至少显式声明 `allow_credentials=False`。

---

### 🟡 L7（低）聊天历史全局共享且无鉴权（用户内容泄漏）

**复现命令**：

```powershell
$H = @("-H","Content-Type: application/json")
curl.exe -s -X DELETE http://127.0.0.1:5211/api/agent/history          # 任何人可清空
curl.exe -s -X POST http://127.0.0.1:5211/api/agent/chat @H -d '{"message":"甲的秘密消息-12345"}'
curl.exe -s http://127.0.0.1:5211/api/agent/history                    # 不带任何 token
```

**实际响应**：`{"history":[{"bot_response":"...","timestamp":"...","user_input":"甲的秘密消息-12345"}]}`
—— **不带 token 的任意调用者可以读到全部用户的对话明文，也可以 DELETE 清空**。
**期望**：聊天历史按 `userId` 分区，或至少要求凭据；未登录时只暴露演示会话。
**根因**：`app/api/chat.py:150-158`（GET/DELETE 均无身份绑定）+ `chat/history.json` 是单一全局文件。
**建议**：`chat_llm` 的历史读写按 `g.current_user`（缺省 `demo-user`）分文件分区。

---

## 3. 验证通过、确认无问题的部分

以下均已**真实调用接口**验证，未发现偏差（每一条都实际跑过，不是读代码推断）：

**契约与数值基线**
- `GET /health` → `200 {"status":"ok"}`；`GET /` 返回服务自描述。
- `POST /api/v1/demo/reset` → `profileVersion=1`、`mastery=[("binary-tree-postorder",42)]`、
  `plan version=1`、`durations=[30,30]`、`factors` 为**数组**（`_factor_rows` 行为符合预期，不作为 Bug）。
- 提交 √√×（preorder=A / inorder=B / postorder=A）→ `assessment.score=66.67`、
  `masteryUpdate 42→58`、`needReplan=true`、`plan.version=2`、`durations=[45,15]`、
  `diff old=1 new=2 changed=[(task-postorder,45),(task-graph,15)]`、
  `trace 3 events / agents={assessment,exercise,secretary} / tools={grade_exercise,select_exercises,update_mastery}`
  —— 与题目给出的已知正确行为**逐项一致**。
- profile / plan / diff / trace 四者数值互相一致（58 / v2 / [45,15] / 3 events）。
- 契约逐字段比对（自写 OpenAPI schema 校验器，只统计 required / type / enum / minimum 违规，
  不把 JSON Schema 默认允许的"未声明附加字段"算作违规）：
  - **全部通过**：`demo/reset`、`profile/{userId}`、`plans/current`、`plans/{id}/diff`（有/无历史两种）、
    `exercises/{setId}`、`traces/{traceId}`、`exercises/{setId}/submit`、`auth/register`(201)、
    `auth/login`、`auth/me`、`auth/logout`、`/api/agent/chat`、`workflows`(POST)、`workflows/{id}`(GET)、
    `workflows/{id}/run`(POST)。
  - 唯一类型违规见 M7（`sessionId`/`userId` 的 int 与 null）。
- `WorkflowRunRequest` **已声明** `answers`（实测契约 `properties = ['answers','submissionId']`）；
  `WorkflowCreateRequest` 已声明 `goal/sessionId/userId/maxSteps/autoRun/answers`，无契约缺口。
- `WorkflowRunResponse` 存在，其 `required` 的 6 个字段实测齐全。

**状态机**
- 完整链路 `create → run(无答案) → run(无答案) → run(√√×) → run` 实测：

  | 步骤 | status | currentAgent | stateVersion | 说明 |
  | --- | --- | --- | --- | --- |
  | create | running | exercise | 1 | `_next_step` 正确识别 demo-user 已有画像+计划 |
  | run1 `{}` | running | exercise | 2 | `awaitingAnswers=true`、`finalAction='提交答案后继续评估'` |
  | run2 `{}` | running | exercise | **2（不推进）** | 无新输入时不重复推进 |
  | run3 带答案 | completed | finish | 4 | 判分 + 落库 + 一次走完 assessment→finish |
  | run4 `{}` | completed | finish | 4 | 终态不再变化 |

- 无卡死、无跳步（除 M1 的 `maxSteps=1` 特例与 M2 的终态重复提交）。
- `maxSteps` 边界：`0` / `-1` / `999` / `true` / `"3"` → 全部 `400` + `{"field":"maxSteps"}`。
- `goal` 缺失 / `null` / 空串 / 纯空白 / 非字符串 → 全部 `400` + `{"field":"goal"}`。
- 重复 `POST /run`（无新输入）不推进 `stateVersion`，也不重复追加 trace（与 `tests/test_workflow_resume.py` 断言一致）。

**幂等**
- 同一 `idempotencyKey` 两次提交响应**逐字节一致**（两次均 1872 bytes，`p1 == p2` 为 True）。
- 不同 key 正常重新判分（42→58→74）；key 按 `userId:setId:key` 隔离，不同用户同 key 互不影响。
- 同 key 携带不同 answers 时返回首次缓存（标准幂等语义，不算 Bug）。

**跨用户数据归属**
- 注册两个真实用户后，各自 profile / plan 独立：甲提交只改甲（甲 mastery 0→16、version 1→2），
  乙保持 0 / version 1；`GET /profile/{自己}` 各自正确。
  （注意：这只证明"按 userId 分流正确"，**鉴权层面的越权见 S5**。）

**demo/reset**
- 清 `workflows`：reset 后 `GET /api/v1/workflows/{旧sid}` → `404`。
- 清 `submissions` / `evidences`：`snapshot.summary.submissionCount` 与 `evidenceCount` 归 0。
- 基线回归：42 / v1 / [30,30]。
- 已知接受项复核：工作流评估路径**不计入** `submissionCount` / `replanRate`
  （实测 4 次 `/submit` + 1 次 workflow 评估后 `submissionCount=4`）。

**已知修复项复核（不重复报告）**
- `/workflows/{id}/run` 的 `answers` 数量护栏：201 条 → `400 {"limit":200,"received":201}`；
  单项 201 字符 → `400 {"limit":200,"received":201}`。
- `answers` 不回显、不落库：run 响应 `state` 不含 `answers`；`repository.json` 中不含 `"answers"`。
- `demo/reset` 清理 workflows。
- `plans/current` 的 `factors` 为数组。

**异常输入不崩（除已列出的 500 之外的都正确降级）**
- 畸形 JSON（`{bad json`）→ `400`；空 body → `400`；非 JSON Content-Type
  （`application/x-www-form-urlencoded` / `text/xml` / 无 CT）→ `400`，均不 500。
- `request.get_json()` 返回 `null`（body 为 `null`）→ 正确按空对象处理。
- 未知 id 全部 `404` 且结构合规：`profile/nobody`、`plans/current?userId=nobody`、`plans/plan-nope/diff`、
  `traces/trace-nope`、`workflows/nope`、`workflows/nope/run`、`exercises/set-nope-001`、
  `exercises/SET-DEMO-BINARY-TREE-001`（大小写敏感，404 合理）。
- `submissionId` 归属校验：不存在的 → `404`；**别人的** submissionId → `404`（未泄漏他人评估）。
- `GET /exercises/{setId}`：`count=0/-1/abc/1e3/0x10` → `400`；`count=999999` 不 OOM。
- `difficulty=bogus` / `knowledgePointId=nope` → `200` + 空数组（契约已声明"允许为空数组"）。
- 契约版本头：`v0.3` → `200`；`v0.2` → `409 CONTRACT_VERSION_MISMATCH`（结构合规）；
  不带头 → 放行（代码注释声明为有意为之，便于 curl 抽查）。
- 所有错误响应（400/404/409/500）都是 `{errorCode,message,details}`，**不含堆栈、不含文件路径、不含内部变量**。

**安全（通过项）**
- **无 SQL 注入面**：全仓无 SQL 拼接（`SqliteRepository` 未被运行时使用；其余走 dict 查找）。
- **无命令注入面**：运行时代码无 `os.system` / `subprocess` / `eval` / `exec`。
- **路径穿越全部失败**：`profile/..%2F..%2Fetc%2Fpasswd`、`profile/%2e%2e%2f%2e%2e%2fdata%2frepository.json`、
  `traces/../../data/repository.json`、`plans/..%2F..%2Fdata%2Frepository.json/diff`、
  `exercises/..%2F..%2Fdata%2Frepository.json` —— 全部 `404`，响应中不含 `"profiles"` 等仓库内容。
- **敏感信息未通过接口泄漏**：`auth/me`、`/`、`agent/health`、`experiments/snapshot`、`profile/{新用户}`、
  `agent/user-data`、`agent/history` 七个响应体，用 11 个探针串（token 全文、`DASHSCOPE`、`sk-`、`api_key`、
  `E:\`、`C:\`、`site-packages`、`Traceback`、`authSubject`、`password`）逐一扫描：
  仅 `agent/history` 命中字符串 `DASHSCOPE`（内容是降级提示文案"未配置 DASHSCOPE_API_KEY"，**不是 Key 值**，
  无实际泄漏）。
- **`_public_user` 视图正确**：`auth/register` / `auth/login` / `auth/me` 的 `user` 对象键为
  `[authProvider, createdAt, grade, lastLoginAt, nickname, userId]`，**不含 `token` / `authSubject` / `status`**；
  token 仅出现在 `register` / `login` 响应（契约要求）。
- **`experiments/snapshot` 匿名化有效**：写入 `userId="secret-user-9999"` 的数据后，
  snapshot 响应体**不含** `secret-user-9999`，也不含 `"userId"` 字段（`_without_identity` 递归剥离生效）；
  `_contains_reasoning` 的 `traceCompliant` 检查正常输出。
- **`agent/user-data` 只暴露 mock 数据**（未泄漏 `sessions`/真实 `users` 表）：
  返回 `users`（mock 的 `u001`）、`courses`(2)、`candidates`(2)、`wrong_questions`(5)，无真实凭据。

**并发（通过项，用于界定 S1 范围）**
- **单进程内** 8 / 16 / 32 / 64 / 128 / 128 并发写（累计 320+ 请求）→ **0 个 500**，无残留 `.tmp`，
  `repository.json` 始终是合法 JSON；12 个并发混合 GET → 全部 200；24 个并发 `POST /workflows` → 全部 200。
  （因此 S1 明确限定为"存在第二个写入方"的场景。）

---

## 4. 未能验证的部分（含原因）

| # | 项目 | 原因 |
| --- | --- | --- |
| 1 | **真实大模型路径**（`app/model_adapters/qwen_adapter.py` 的 `safe_decide`、`app/agent/chat_llm.py` 的 LLM 分支） | 环境未配置 `DASHSCOPE_API_KEY`。实测 `GET /api/agent/health` 返回 `llm_ready=false`，所有 chat 响应 `llmUsed=false`，`model_decider` 恒为 `None` → `decide_next_step` 的模型分支（`app/runtime/orchestrator.py:51-58`）与 `chat_llm` 的 LLM 调用路径**完全未被覆盖**。`GET /api/agent/history` 中 14 条记录全部是"本地确定性规则"文案，可佐证。 |
| 2 | **`qwen_adapter` 与 `chat_llm` 默认 `LLM_MODEL` 不一致** | 按题目要求**不重复报告**，未展开验证。 |
| 3 | **同进程内多线程 `_flush()` 竞态是否真会 500** | 已尽力构造（单进程 320+ 并发写，含 7MB / 53MB 大仓库，含 200KB 载荷放大写入窗口）→ **0 次失败**。因此把 S1 的结论限定在"跨进程/多 worker"，并标注需第二写入方才能触发。**无法确认**单进程内是否存在极低概率窗口，故不断言。 |
| 4 | **`data/repository.json` / `chat/history.json` 的精确计数类断言** | 本工作区有**其它进程共享同一份数据文件**（曾观察到非本次请求产生的 `evidence-submit-concurrent-real-0` 记录；`users` 集合在本次排查开始前已有 16 条）。因此所有计数结论都以"同批请求内的前后对照"为准，未使用跨批次的绝对数值。 |
| 5 | **限流 / 超时 / 超大文件 DoS 的完整评估** | 服务端无任何限流中间件（无 `MAX_CONTENT_LENGTH`、无速率限制）。已实测 1MB `goal`、1MB `message`、20 万字符 `idempotencyKey` 均被接受；更大的载荷（如 100MB body）未测试，以免影响共享环境。 |
| 6 | **`app/api/workflows.py:100` 的 `profile.get("mastery", [{}])[0]` 在 `mastery` 为空数组时是否 IndexError** | 静态阅读发现 `mastery == []` 时会 `IndexError` → 500，但**没有任何接口能构造出 `mastery=[]` 的画像**（`provision_starter_profile` 与 `demo/_demo_state` 都保证至少 1 条）。标记为**疑似**，未列为 Bug。 |
| 7 | **`tests/` 全量回归** | 本次为只读排查，未修改代码，也未运行 pytest（题目要求"真跑接口"）。仅在区分"已修/未修"时阅读了 `tests/test_workflow_resume.py` 的断言。 |
| 8 | **前端实际调用面 vs 后端实现**的完整比对 | 只比对了 `contracts/openapi.json` 与后端路由。仓库内的鸿蒙前端代码未纳入本次排查范围（另有 `docs/07`、`docs/08` 覆盖）。已确认的缺口是 L3（5 条路由未进契约）。 |

---

## 5. 排查过程备注

1. **服务被外部终止 2 次**：分别在发出约 100 次与 200 次请求后，进程在**空闲时**被终止（无 traceback、无 OOM 迹象，
   job 退出码 1）。怀疑与同工作区其它进程的清理动作有关。处置：改为**单条命令内完成"起服务 → 等健康检查 → 跑用例 → 停服务"**
   （脚本 `run_probe.ps1` / `run_multi.ps1`），此后全部 11 个批次零中断完成。
2. **500 会向 stderr 打印完整 traceback**：大量 500 探测会让服务端日志迅速膨胀（这本身也是 S1/S2 之外的运维风险点）。
   为控制输出量，后续批次通过一个 `logging.disable(logging.CRITICAL)` 的启动包装器运行（**只影响日志，不影响 HTTP 行为**），
   500 的状态码与响应体已在前序批次中留档，根因栈也已抓取。
3. **未修改任何源码**。排查期间唯一被写入的项目内文件是 `data/repository.json`（服务自身的运行时数据，
   由 `demo/reset` 与探测请求写入），以及 `chat/history.json`（由 chat 接口写入）。
   **结束前已执行 `POST /api/v1/demo/reset` 恢复演示基线**：`repository.json` 从 230,245 字节回到 31,927 字节，
   `profileVersion=1 / mastery=42 / plan version=1 / durations=[30,30]`。
   残留：`users` 21 条、`profiles` 22 条（其中多数由本工作区历次测试脚本创建；`demo/reset` **按设计不清
   users/profiles**，见 M5）。如需彻底干净，可删除 `data/repository.json` 后重启（`ensure_demo_data()` 会自动重建演示基线）。
4. **进程清理**：所有由本次排查启动的服务进程均由 `Stop-Process -Id` 显式结束；
   排查结束时 `Get-Process python` 计数为 **0**，`5210–5219` 端口无监听。
5. 同路径旧版本报告与 `docs/_probe/` 目录（前任代理产出）**已被本报告取代 / 保留未动**。
   旧报告的核心结论之一"单机并发写 500 率 75%–97%"在本环境**未能复现**（单进程 320+ 并发写 0 失败）；
   本次以可复现的"**跨进程**双实例并发 5%–19%"为准（见 S1），并明确了触发前提。
