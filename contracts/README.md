# API 契约说明

`openapi.json` 是前端、后端和离线 Fixture 的共同字段基线，当前版本为 `api-contract-v0.3`。前端请求统一携带 `X-API-Contract-Version: api-contract-v0.3`，并以 GitHub `backend` 分支中的同名契约为唯一真源。

## 文件映射

| 接口 | 请求阶段 | Fixture 文件 |
| --- | --- | --- |
| `POST /api/agent/chat` | 对话卡片 | `fixtures/chat-response.json` |
| `POST /api/v1/agent/proactive` | 主动提醒与情境建议 | 前端 Fixture 内置确定性响应 |
| `POST /api/v1/workflows` | 创建诊断工作流 | `fixtures/workflow-created.json` |
| `POST /api/v1/workflows/{sessionId}/run` | 推进 Agent 工作流 | 前端 Fixture 内置确定性响应 |
| `GET /api/v1/workflows/{sessionId}` | 诊断中 / 完成 | `fixtures/workflow-running.json`、`workflow-completed.json` |
| `GET /api/v1/profile/{userId}` | 诊断前 / 诊断后 | `fixtures/profile-v1.json`、`profile-v2.json` |
| `GET /api/v1/plans/current` | 重规划前 / 重规划后 | `fixtures/plan-v1.json`、`plan-v2.json` |
| `GET /api/v1/exercises/{setId}` | 三题诊断 | `fixtures/exercise-set.json` |
| `POST /api/v1/exercises/{setId}/submit` | 评估与重规划 | `fixtures/exercise-submission-result.json` |
| `GET /api/v1/plans/{planId}/diff` | V1/V2 差异 | `fixtures/plan-diff.json` |
| `GET /api/v1/traces/{traceId}` | 诊断前 / 完成后 | `fixtures/trace-before.json`、`trace-after.json` |
| `POST /api/v1/demo/reset` | 重置固定演示 | `fixtures/demo-reset.json` |
| `GET /api/v1/experiments/snapshot` | 导出匿名实验数据 | 仅真实后端 |

## 修改规则

1. 接口字段变化先修改 `openapi.json`，并提升契约版本。
2. 同步更新对应 fixture、ArkTS DTO 和页面格式化逻辑。
3. 运行 `tools/validate_contract.ps1`，再构建主 HAP 和测试 HAP。
4. `backend/v1_routes.py` 提供可联网联调的状态化契约演示服务；生产算法尚未接入的字段仍使用明确的演示数据，禁止把 `/api/v1` 请求偷偷改接到聊天接口。

后端契约回归可在仓库根目录运行：

```powershell
python -m unittest discover -s backend -p 'test_*.py' -v
./tools/run_backend_core_regression.ps1
```

固定核心链必须始终满足：初始 mastery 42 → 三题得分 67% → mastery 58 → Plan V2 → 专项时长 30 分钟调整为 45 分钟 → Trace 状态版本 1–5。
