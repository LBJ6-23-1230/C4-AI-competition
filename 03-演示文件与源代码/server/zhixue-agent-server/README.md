# zhixue-agent-server

「知学 Mate」的 Python Agent 后端。单进程同时提供**两层**能力：

| 层 | 端点 | 职责 |
|---|---|---|
| 自然语言层 | `POST /api/agent/chat` | LLM 意图识别 + 多模态识图 + 6 路子 Agent |
| 结构化工作流层 | `/api/v1/**` | Agent 循环 + **确定性**判分/掌握度/优先级/重规划 |

> **设计纪律（本项目最重要的技术主张）**：大模型只负责「理解意图」与
> 「生成自然语言」，**所有业务计算一律留在确定性代码里**
> （见 `app/decision/`、`app/tools/`）。因此同一份输入永远得到同一个分数，
> 不受模型随机性影响。

## 快速开始

```bash
python -m venv .venv && .venv/Scripts/activate     # Windows
pip install -r requirements.txt
cp .env.example .env                                # 填入 DASHSCOPE_API_KEY（可选）
python run.py                                       # 默认监听 0.0.0.0:5000
```

**不配 Key 也能跑**：聊天层会自动降级为确定性规则，并在回复里明确标注
"本次大模型调用失败/未接入"，**绝不伪装成真实模型输出**
（响应里的 `llmUsed` 字段供前端显示来源标签）。

## LLM 路由

| 变量 | 用途 | 默认值 |
|---|---|---|
| `LLM_MODEL` | 文本意图识别与回复 | `qwen-vl-max` |
| `LLM_VL_MODEL` | 图片识别 | `qwen-vl-max` |
| `LLM_DECISION_MODEL` | 工作流结构化决策 | `qwen-plus` |
| `EMBED_MODEL` | 知识库语义检索向量 | `text-embedding-v3` |

两条路径分开是**刻意设计**：识图需要 VL 模型，工作流决策用更便宜的纯文本
模型，避免占用 VL 配额。不要为了"统一"改成同一个模型。

> ⚠️ 默认值为何是 `qwen-vl-max` 而非 `qwen-vl-plus`：本项目**实测**当前账号下
> `qwen-vl-plus` 返回 `403 AllocationQuota.FreeTierOnly`（免费额度不可用），
> 照旧默认值会在第一次识图请求就失败。可用
> `tools/check_llm_ready.ps1` 做逐模型自检。

## 持久化

- **默认**：JSON，落在 `data/repository.json` —— 可直接肉眼查看，便于答辩演示与人工核对
- **多进程部署**：设 `ZHIXUE_DB=sqlite`（或 `ZHIXUE_DB=sqlite:<path>`）
  改用并发安全的 SQLite 后端

> 注意：`data/repository.json` 与 `chat/history.json` 是**运行期状态**，
> 已在 `.gitignore` 中，绝不入库、绝不进交付包。

## 幂等与并发

以下四处「读—改—写」序列均已加锁，避免并发丢更新：

| 位置 | 保护 |
|---|---|
| `chat/history.json` | 模块级锁 + `os.replace` 原子落盘 |
| `POST /api/v1/exercises/{setId}/submit` | 幂等键检查 → 判分 → 掌握度回写整段串行 |
| `EventStore.append`（trace） | 模块级锁 |
| `_run_saved_workflow`（工作流推进） | 可重入锁（`autoRun` 分支同样持锁） |

## 鉴权

| 端点 | 说明 |
|---|---|
| `POST /api/v1/auth/register` | 手机号**必填**；重复手机号返回 409 |
| `POST /api/v1/auth/login` | 昵称免密登录（仅演示/单机场景） |
| `POST /api/v1/auth/send-code` | 手机验证码签发 |
| `POST /api/v1/auth/verify-code` | 验证码校验（200 已存在 / 201 新建） |
| `POST /api/v1/auth/login-with-huawei` | 华为账号一键登录（客户端传 `openId`） |
| `DELETE /api/v1/auth/account` | 注销账号 |

未配置短信服务商时，开发模式返回 `devCode` 且 `smsDelivered=false`；
生产模式**拒绝**暴露开发码。

> ⚠️ `login-with-huawei` **不校验 OpenID 真伪**（那需要服务端调华为接口验签）。
> 演示/单机场景可用；生产环境必须补上验签，否则伪造 `openId` 即可登入他人账号。
> 详见 `docs/13`。

## 测试

```bash
python -m pytest -q                                  # 320 项单元测试
python ../../integration/run_liantiao5.py            # 契约 + 单测 + 95 项 HTTP + 归档
```

## 契约

`../../contracts/openapi.json` 是前后端唯一接口真源（`api-contract-v0.3`），
`app/contracts/openapi.json` 是逐字节一致的镜像。
请求需携带 `X-API-Contract-Version: api-contract-v0.3`（不带头时放行）。
