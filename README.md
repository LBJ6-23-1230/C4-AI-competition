# 知学 Mate · 后端工作包（liantiao4）

> **收件人**：后端同学
> **基线**：后端 282/282 测试 · HTTP 联调 95/95 · 演示基线 6 项零漂移

## 这个包里有什么

```
server/zhixue-agent-server/   后端唯一真源（Flask，单进程提供两层）
  app/api/                      REST 端点
  app/agent/                    自然语言层（LLM 意图识别 + 多模态）
  app/runtime/                  工作流层（真 Agent 循环）
  app/auth/                     鉴权（手机号验证码 / 华为账号）
  app/tools/ app/decision/      确定性计算（判分、优先级、重规划）
  tests/                        282 项测试 + conftest.py
  data/                         question_bank.json + repository.json
contracts/openapi.json          ★ 契约真源（权威）
integration/                    一键联调脚本
tools/                          契约补丁与审计工具
docs/                           给你的任务书与相关报告
evidence/                       最近一次联调证据
```

**包里没有**：`app/`（前端工程）、`__pycache__`、`.env`、`.pytest-tmp`。
**注意**：联调脚本已处理"无前端目录"的情况（契约闸门会跳过镜像比对）。

## 怎么开始

1. **读 `docs/16-后端同学任务书.md`** —— 你的工作清单
2. 启动服务：

```powershell
cd server\zhixue-agent-server
$env:PORT = "5000"
& <你的python> run.py
```

3. 跑一键自检（**从包根目录执行**）：

```powershell
& <你的python> integration\run_liantiao4.py --port 5297
```

它会依次做：契约闸门 → 282 项测试 → 拉起服务 → 95 项 HTTP 验证 → 归档证据。
**退出码 0 = 可以合并。**

真实 LLM 模式：

```powershell
& <你的python> integration\run_liantiao4.py --port 5297 --llm-mode live
```

## 你需要知道的关键约定

| 约定 | 说明 |
|---|---|
| 契约 | `contracts/openapi.json` 是**真源**；前端那份是镜像，改完两边要一致 |
| 身份解析 | 统一走 `app/api/identity.py` 的 `resolve_user_id()`，不要自己写 `args.get("userId")` |
| 演示基线 | `66.67` / `全错 0.0` / `42→58` / `planVersion [1,2]` / 时长 `[[30,30],[45,15]]` **六个数字不可漂移** |
| 测试命令 | `python -m pytest tests/ -q` —— **不要加 `--basetemp`**（会抛 PermissionError） |
| `run.py` / `conftest.py` | 由联调负责人维护，改动前请先沟通 |
| LLM 模型分工 | 自然语言层 `LLM_MODEL` / `LLM_VL_MODEL` 默认 `qwen-vl-plus`；工作流决策层 `LLM_DECISION_MODEL` 默认 `qwen-plus`，这是刻意分工 |
| 数据部署 | 单进程演示默认 JSON；多进程部署设置 `ZHIXUE_DB=sqlite`，使用并发安全的 SQLite 后端 |

## 本轮工作清单

| 状态 | 事项 |
|---|---|
| ✅ | 工作流评估写入 `submissions`，`replanRate` 改用 `plan_histories` 口径 |
| ✅ | 手机号验证码接口：哈希存储、60 秒限流、24 小时上限、5 次锁定、开发模式回显 |
| ✅ | 真实 LLM 文本与多模态链路验证通过，均返回 `llmUsed=true` |
| ✅ | 10 次真实 LLM 端到端稳定性验证：`282/282`、`95/95`、基线无漂移 |
| ✅ | `DASHSCOPE_API_KEY` 已由接收方配置（`.env` 不进入交付包） |
| 不适用 | 当前交付包不含 `archive/`，无需清理死代码 |
