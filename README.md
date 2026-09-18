<div align="center">

# 知学 Mate（ZhiXue Mate）

**会主动找你的 AI 学习搭子**

HarmonyOS 原生应用 · ArkTS 前端 + Python Agent 后端

[![Platform](https://img.shields.io/badge/Platform-HarmonyOS-1F4E79?style=flat-square)](https://developer.huawei.com/consumer/cn/)
[![SDK](https://img.shields.io/badge/SDK-6.1.1(24)-2563EB?style=flat-square)](https://developer.huawei.com/consumer/cn/)
[![Frontend](https://img.shields.io/badge/Frontend-ArkTS-10B981?style=flat-square)]()
[![Backend](https://img.shields.io/badge/Backend-Python%203.12%20%2B%20Flask-B45309?style=flat-square)]()
[![Contract](https://img.shields.io/badge/Contract-api--contract--v0.3-0F766E?style=flat-square)]()

**2026 中国高校计算机大赛 · 人工智能创意赛 · 鸿蒙赛道 · Agent 创新方向**

团队：**暗影骑士王们**（武汉理工大学）｜复赛提交截止：**2026-09-30 24:00**

</div>

---

## ⚠️ 先读这一段：仓库布局与版本状态

### 分支布局

| 分支 | 内容 | 文件数 |
|---|---|---|
| **`main`** | 本 README（项目总说明） | 2 |
| **`backend`** | Python Agent 后端（`zhixue-agent-server/`）+ 契约 + 后端文档 | 79 |
| **`frontend`** | ArkTS 前端工程 + 契约 + 文档 + 联调工具 | 147 |

**想跑起来，用这一条命令取到完整工程：**

```bash
git clone -b frontend --single-branch https://github.com/LBJ6-23-1230/C4-AI-competition.git zhixue-mate
cd zhixue-mate
powershell -ExecutionPolicy Bypass -File tools\start_dev.ps1   # 启动后端
# 再用 DevEco Studio 打开本目录
```

> `frontend` 分支内已包含一份可直接运行的后端（`backend/`），
> 因此**只克隆 `frontend` 就能跑通全部演示**，无需再拉 `backend`。

### 📌 版本差异须知（重要）

**本 README 描述的是"前后端合并后的最新工程"（18 页面 · 含登录 · 含智能体页）。**

而 GitHub 上的 `frontend` 分支**尚未同步**这批改动 —— 它停留在较早的版本：

| 能力 | README 描述 / 合并版 | `frontend` 分支现状 |
|---|---|---|
| 页面数 | 18 | 16 |
| 用户登录 / 账号页 | ✅ 已实现 | ❌ 无 |
| 智能体能力网格 | ✅ 12 项卡片 | ❌ 无（仅 6 个意图 chip） |
| 对话优先首屏 | ✅ 引导式 | ⚠️ 部分 |
| 底部四标签导航 | ✅ | ❌ |
| 后端鉴权 `/api/v1/auth/*` | ✅ 5 个接口 | ❌ |
| 后端单元测试 | **90** 个 | 70 个 |
| 联调自检 | **104** 项 | 无此脚本 |
| ArkUI-X 构建插件 | ✅ 已切回标准插件 | ❌ **仍带 ArkUI-X，会导致 Sync 失败** |

> **结论**：本 README 是**目标状态与项目全貌**的说明；
> 若要拿到与之匹配的可运行代码，需团队把合并版工程推送到远端
> （见文末「仓库结构现状与待办」）。

---

## 一句话介绍

**知学 Mate 是一个会主动算、并且算得出来的学习搭子。**

它感知你的课程表、考试倒计时、作业 DDL、错题记录与空闲时间，
用**确定性算法**算出「今天最该做的一件事」，把它变成可执行的任务，
并在你完成的每一次练习后自动更新掌握度、重排计划。

它不只回答问题 —— 它**推动**你行动。

---

## 核心设计：判断是「算式」，不是「模型觉得」

这是本项目最值得讲的一点，也是它区别于普通「套壳 AI 应用」的地方：

| 谁在干活 | 负责什么 | 是否进入 prompt |
|---|---|---|
| **大模型（通义千问 Qwen-VL）** | 只回答"下一步该叫谁"、生成自然语言回复、识别错题图片 | ✅ |
| **确定性代码** | 判分、掌握度更新、五因子优先级、计划重规划、主动服务决策 | ❌ **一行都不进** |

**由此得到一个可验证的强结论：拔掉大模型，整个闭环依然跑得完。**

所有业务计算都是可复现的纯函数，模型只是编排层的一个可选组件。
这不是宣传语 —— 后端单元测试与联调脚本里都有对应断言。

### 五因子决策模型

「今天最该学什么」不是黑盒判断，而是五个因子加权求和：

```
优先级 = 1−掌握度 × 0.30
       + 错误强度 × 0.25
       + 课程重要性 × 0.20
       + 时间紧迫度 × 0.15
       + 先修影响 × 0.10
```

**这条算式在前端是可见的** —— 「为什么是它」面板可逐行展开贡献值：

```
1 − 掌握度        0.58 × 0.30 = 0.174
错误强度          0.67 × 0.25 = 0.168
课程重要性        0.90 × 0.20 = 0.180
时间紧迫度        0.53 × 0.15 = 0.080
先修影响          0.20 × 0.10 = 0.020
─────────────────────────────────────
综合优先级                     0.62
```

答辩时评委问「为什么推荐先学二叉树」，打开这一页逐行念即可 ——
**从"模型觉得"变成"算式算的"。**

---

## 界面结构（18 页面）

### 设计原则：对话用于表达，能力页用于发现

应用**启动即进入对话页**——可以直接说话，不用先找功能。
「Agent 会做什么」单独放在智能体页，而不是把一堆入口塞在首屏。

```
┌─ 对话页 ──────────────┐   ┌─ 我的智能体 ─────────────┐
│ 早上好，                │   │ 分类：全部/诊断/练习/计划…  │
│ 从今天最该做的一件事开始 │   │ ┌────────┐ ┌────────┐   │
│                        │   │ │错题诊断 │ │学情画像 │   │
│ ┌────────────────────┐ │   │ │一句话说明│ │一句话说明│   │
│ │ 说说你想做什么…      │ │   │ │可用 使用↗│ │可用 使用↗│   │
│ └────────────────────┘ │   │ └────────┘ └────────┘   │
│ [今日建议][薄弱诊断]…    │   │        … 12 项 …        │
├────────────────────────┤   ├─────────────────────────┤
│ ◈对话  ▦智能体  ◷计划  ◉我的 │ ◈对话  ▦智能体  ◷计划  ◉我的 │
└────────────────────────┘   └─────────────────────────┘
```

### 四标签导航

| 标签 | 作用 | 内容 |
|---|---|---|
| **对话** | 直接对 Agent 说话 | 问候引导 + 大输入框 + 6 个意图快捷 chip |
| **智能体** | 发现 Agent 会做什么 | **两列能力卡片网格（12 项）**，每卡带分类、说明、可用状态与「使用 ↗」 |
| **计划** | 推进本周计划 | 完整计划 + 建议 / 错题 / 决策轨迹入口 |
| **我的** | 账号与隐私 | 身份引导 + 学习记录 / 课程作业入口 |

### 12 项智能体能力

| 分类 | 能力 | 说明 |
|---|---|---|
| 计划 | 今日学习建议 | 按紧迫度与薄弱点算出最优任务 |
| 计划 | 学习计划 | 周计划与任务时长，自动重规划 |
| 诊断 | 错题诊断 | 拍照识别知识点与错误类型 |
| 诊断 | 学情画像 | 雷达图呈现掌握度与薄弱维度 |
| 练习 | 专项练习 | 确定性判分 + 掌握度更新 |
| 练习 | 专注模式 | 普通 / 严格双模式计时 |
| 陪伴 | 学习搭子匹配 | 四因子匹配学习伙伴 |
| 对话 | 自然语言提问 | 意图识别 + 结构化卡片回复 |
| 数据 | 课程与作业 | CSV/JSON 导入课表与 DDL |
| 数据 | 学习记录 | 专注时长与完成率趋势 |
| 审计 | Agent 决策过程 | 时间线呈现智能体与工具调用 |
| 审计 | 学习复盘 | 汇总任务、知识点、徽章与下一步 |

### 完整页面清单

| 分类 | 页面 |
|---|---|
| **入口** | `Login` 登录 · `Index` 工作台（智能体网格 / 计划 / 我的）· `ChatMain` 对话 · `Account` 我的 |
| **学习闭环** | `StudySuggestion` → `WrongQuestion` → `ExercisePractice` → `StudyTags` → `StudyPlan` |
| **专注** | `FocusSetup` → `FocusTimer` → `FocusResult` · `LearningHistory` |
| **社交 / 复盘** | `PartnerMatch` 学习搭子 · `ReviewSummary` 学习复盘 |
| **审计 / 调试** | `AgentTrace` 决策轨迹 · `ApiEnvironment` 接口环境 · `CourseImport` 课程与作业 |

> **每个终点页都有「接下来」卡**：错题诊断完 → 做同类专项题；
> 练习判分完 → 再练一组或看更新后的画像；看完画像 → 按薄弱点开始练习。
> Agent 的第 5 层「输出层」必须落在界面上，而不是把数据摊开就结束。

---

## 技术架构

```
┌──────────────────────────────────────────────────────────────┐
│              HarmonyOS ArkTS 前端（18 页面）                   │
│                                                              │
│   AgentBridge ──┐                                            │
│   ViewModels  ──┼──► AgentApiClient（唯一 HTTP 入口）          │
│   ProactiveVM ──┘         │                                  │
└───────────────────────────┼──────────────────────────────────┘
                            │  单一 baseUrl · api-contract-v0.3
                            ▼
┌──────────────────────────────────────────────────────────────┐
│              统一后端（单进程 · 单端口 5000）                   │
│                                                              │
│  ① 自然语言层  POST /api/agent/chat                           │
│     LLM 意图识别 → 6 路子 Agent → Qwen-VL 多模态识图            │
│     └ 无 Key / 调用失败 → 确定性规则兜底，并显式标注降级          │
│                                                              │
│  ② 结构化工作流层  /api/v1/**                                  │
│     demo · workflows · profile · plans · exercises · traces   │
│     agent/proactive · experiments · auth                      │
│     └ 真 Agent 循环：secretary → exercise → assessment         │
│     └ 确定性工具：grade_exercise / update_mastery / replan      │
│     └ trace 留痕（3 事件 / 3 agent / 3 tool），不含思维链         │
└──────────────────────────────────────────────────────────────┘
```

### 技术栈

| 层 | 选型 |
|---|---|
| 前端 | ArkTS / ArkUI 声明式 UI · HarmonyOS SDK **6.1.1(24)** · 18 页面 |
| 后端 | Python **3.12** + Flask 3.x · 单进程单端口 |
| 大模型 | 通义千问 `qwen-vl-plus`（DashScope 兼容模式，支持多模态识图） |
| 契约 | `api-contract-v0.3`（前后端 `openapi.json` 逐字节一致） |
| 持久化 | 仓储层已抽象（`Repository` 协议），当前实现为 JSON 单文件 |
| 登录 | 免密昵称注册 + 长期 token；鉴权**可选**，不做门禁 |
| 测试 | 后端 **90** 个单元测试 · 联调自检 **104** 项断言 |

---

## 快速开始

### 前置条件

- **DevEco Studio** + **HarmonyOS SDK 6.1.1(24)**
- **Python 3.12+**（工程使用 `str | Path` 语法，3.8 无法运行）
- 环境变量 `DEVECO_SDK_HOME` 指向 DevEco 的 `sdk` 目录

### 1. 取代码

```bash
git clone -b frontend --single-branch https://github.com/LBJ6-23-1230/C4-AI-competition.git zhixue-mate
cd zhixue-mate
```

### 2. 启动后端

```powershell
# 首次：准备 Python 环境
uv venv ..\.venv-lt --python 3.12
uv pip install --python ..\.venv-lt\Scripts\python.exe flask flask-cors "openai>=1.0.0" python-dotenv pytest

# 一键启动（自动找解释器、查依赖、提示 Key 状态）
powershell -ExecutionPolicy Bypass -File tools\start_dev.ps1
```

看到 `监听地址 : http://0.0.0.0:5000` 即成功。

**可选但强烈建议** —— 配置大模型，激活错题拍照识别：

```powershell
cd backend
Copy-Item .env.example .env
notepad .env      # 填入 DASHSCOPE_API_KEY=sk-xxxx
```

> 不配 Key 也能完整跑通演示：聊天层会降级为确定性规则，
> **并在回复里显式标注"不是大模型输出"** —— 不伪装、不静默兜底。

### 3. 打开前端

1. DevEco Studio 打开项目根目录
2. **Sync and Refresh Project**
3. 配置签名（`File > Project Structure > Signing Configs > 自动生成`）
4. 选 `entry` 模块运行到模拟器 / 真机

### 4. 联调地址怎么填（最容易踩的坑）

| 运行环境 | baseUrl |
|---|---|
| HarmonyOS 模拟器 | `http://10.0.2.2:5000` |
| HarmonyOS 真机（同一 WiFi） | `http://<开发机局域网IP>:5000` |
| 桌面预览 / 浏览器 | `http://127.0.0.1:5000` |

**不必改代码**：App 内「接口环境」页可直接填写并持久化。
无网络时也可一键切「离线 Fixture」，用本机数据完整演示（判分规则与后端一致）。

---

## 登录与身份

登录定位是「**Agent 的身份锚点**」，不是门禁。

| 入口 | userId | 需要后端 | 用途 |
|---|---|---|---|
| **一键体验**（主按钮） | `demo-user` | ❌ | 评委 / 演示永远点这个，零摩擦 |
| **昵称注册** | 服务端下发 `u-xxxx` | ✅ | 建立自己的画像，学习记录归到自己名下 |
| **跳过 → 离线模式** | `demo-user` | ❌ | 自动切 Fixture，断网也能进 |

**四条关键设计**（都是为了让登录不伤害演示）：

1. **游客优先，绝不硬门禁** —— 未登录用约定的 `demo-user`，可跑通全部页面。
2. **演示基线零影响** —— `demo/reset` 只作用于 `demo-user`，`mastery 42 / Plan V1 [30,30] / √√× → 66.67 → 58` 逐项不变（有 31 项断言守着）。
3. **鉴权可选，不是门禁** —— 不带 token 按游客处理；带无效 / 过期 token **降级为游客而不是 401**，避免一个过期票据把整个 App 打成不可用。
4. **不做密码体系** —— 本工程没有需要密码保护的数据。注册只取昵称 + 年级，服务端下发长期 token（30 天）。生产化路径是接入 **AGC 认证服务**。

> ⚠️ **关于登录页的密码输入框**：界面按设计稿渲染了密码字段与「密码登录 / 验证码登录」分段，
> 但**密码不参与任何后端校验**，账号身份仍由「昵称 + token」确定，页面上有明确文案标注。
> 这是**刻意的视觉完整、语义占位**——答辩演示不缺元素，同时不引入密码存储的合规负担。
> 验证码登录需短信服务，比赛期间不接入。

### 接口

```
POST   /api/v1/auth/register   {nickname, grade?}  → {user, token, expiresAt}   201
POST   /api/v1/auth/login      {userId, token}     → {user, token, expiresAt}
POST   /api/v1/auth/logout     (Bearer)            → {status}
GET    /api/v1/auth/me         (Bearer)            → {user}
DELETE /api/v1/auth/account    (Bearer)            → {status: deactivated}
```

---

## 核心演示流程（可复现的数值）

| 步 | 操作 | 看到什么 |
|---|---|---|
| 1 | 启动 App | 停在对话页，可点「跳过登录，用演示身份进入」 |
| 2 | 切「智能体」标签 | 12 张能力卡片，含分类筛选 |
| 3 | 点「今日学习建议」卡 | 回到工作台，显示「今日最优任务：二叉树后序遍历 **45 分钟** · 考试还有 5 天」 |
| 4 | 展开「为什么是它」 | 五行因子贡献值 + 综合优先级 |
| 5 | 点「开始专注」 | 进入专注设置，任务已预填 |
| 6 | 「智能体 → 错题诊断」拍一道题 | 知识点、错误类型、3 条补强建议（配 Key 时为真实 Qwen-VL 识别） |
| 7 | 点「做 3 道同类专项题」 | 进入练习页 |
| 8 | 答案选 **A / B / A** 并提交 | **得分 66.67%** · 掌握度 **42 → 58** |
| 9 | 继续下滑 | 计划 **V1 → V2**，任务时长 **45 / 15** |
| 10 | 点「再练一组同类题」 | 页面内重开一轮 |
| 11 | 点「看 Agent 决策过程」 | `secretary → exercise → assessment`，3 个工具全部留痕 |

### ⚠️ 四个锁死的值（改动会全线崩）

```
exercise-preorder-001  = "A"
exercise-inorder-001   = "B"
exercise-postorder-001 = "C"      ← 注意是 C，不是 A
三题必须共用 knowledgePointId = "binary-tree-postorder"
```

演示提交 √√×（即 A / B / A）才是 2 对 1 错 = **66.67**。

---

## 如何验证它「真的是个 Agent」

### 证据一：判分真的随答案变化

**这是主动邀请评委现场做的事**：

| 提交 | 得分 |
|---|---|
| 全对（A / B / C） | **100.0** |
| √√×（A / B / A） | **66.67** |
| 全错 | **0.0** |

离线 Fixture 模式下同样成立。

### 证据二：一次 workflow 真的跨越多个智能体

实测（`GET /api/v1/traces/{traceId}`）：

| 指标 | 实测值 |
|---|---|
| trace 事件数 | 3 |
| 不同 agent | `secretary` · `exercise` · `assessment` |
| 不同 tool | `grade_exercise` · `select_exercises` · `update_mastery` |
| 是否含模型思维链 | ❌ 不含（符合竞赛红线） |

### 证据三：拔掉大模型依然跑完

不配 `DASHSCOPE_API_KEY` 直接启动，走完上述全流程，数值完全一致。
后端另有断言验证「两次独立运行的 agent 序列完全一致」（确定性）。

### 一条命令跑完全部验收

```powershell
python tools\verify_liantiao1.py --start-server
# 退出码 0 = 全部通过；原始输出写入 evidence\verify_result.json
```

| 组 | 项数 | 覆盖内容 |
|---|---|---|
| ⓪ 静态一致性 | 18 | 契约逐字节一致、无硬编码地址、单一真源、文件齐备 |
| ① 后端单元测试 | 1 | `90 passed` |
| ② 契约主链 | 22 | reset → 题集 → 提交 → 画像 → 计划 → diff 的每个数值 |
| ③ 回归护栏 | 9 | **旧缺陷不得复现**：判分随答案变化、全错不涨掌握度、时长不漂移、幂等重放 |
| ④ Agent 循环 | 23 | 真循环、trace ≥2 agent/≥3 tool、确定性、proactive、聊天层 |
| ⑤ 登录 / 鉴权 | 31 | 注册/登录/退出/注销 + **演示基线护栏** |
| **合计** | **104** | **104/104 通过** |

连续回归（复赛要求"主链连跑 ≥10 次"）：

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_backend_core_regression.ps1
# 实测：Backend v0.3 regression: 10/10 runs passed
```

---

## 工程设计上的几个取舍（供评审参考）

| 取舍 | 选择 | 理由 |
|---|---|---|
| **鉴权** | 可选 Bearer，不是门禁 | 评审现场一个过期 token 不该让整个 App 不可用；**演示基线完全不受影响**（31 项断言守着） |
| **登录方式** | 免密昵称注册 | 本工程没有需要密码保护的数据；密码字段是视觉占位，避免密码存储的合规负担 |
| **降级策略** | 显式标注，不静默伪装 | 缺 Key 时回复会写明"以上由本地确定性规则生成，不是大模型输出" |
| **离线 Fixture** | 保留，判分规则与后端**逐条对齐** | 现场网络不可控，必须能离线演示；判分不能因为是离线就失真 |
| **持久化** | JSON 单文件 | 演示零运维；仓储层已抽象，换 SQLite/AGC **只需改一行** |
| **首页形态** | 对话优先 + 能力页分离 | Agent 的价值是"你直接说它就能做"，而不是让人先读一遍功能清单 |

---

## 已知边界（诚实声明）

| 范围 | 状态 |
|---|---|
| 后端逻辑、契约、判分、Agent 循环 | ✅ 真实 HTTP 实跑验证（104/104） |
| 后端单元测试 / 连续回归 | ✅ `90 passed` / `10/10 runs passed` |
| 前端编译 | ✅ `BUILD SUCCESSFUL`，可产出 HAP（1.7 MB，unsigned） |
| **前端交互（设备上点击流程）** | ⚠️ **未完成设备验证** —— 编译通过 ≠ 交互正确 |
| 真实 LLM 调用 / 图片 OCR | ⚠️ 需配置 `DASHSCOPE_API_KEY` 后验证 |
| HAP 签名安装 | ⚠️ 仅缺签名配置 |
| 验证码登录（短信） | ❌ 未实现（界面已占位） |
| 服务卡片 / 后台代理提醒 / 语音 / 位置 | ❌ 尚未实现（Agent 赛道「主动服务」的下一步） |
| 平板 / PC 侧边栏适配 | ❌ 尚未实现（当前为手机版，导航落在底部标签） |

---

## 仓库结构现状与待办

### 三个已知问题（团队内部待处理）

**1️⃣ 默认分支看不到代码** —— 评审打开仓库首页只能看到 LICENSE 与本文档，
容易误判为"仓库是空的"。竞赛要求提交「项目运行所需的**所有工程文件**」，
**建议将合并后的完整工程推送为 `main`。**

**2️⃣ `frontend` 分支带遗留的 ArkUI-X 构建插件** —— 该分支的
`hvigor/hvigor-config.json5` 依赖 `@ohos/hvigor-ohos-arkui-x-plugin`，
会导致 hvigor Sync 报 `Unable to find 'arkui-x.dir'`。
但工程的 `runtimeOS` 已是纯 `HarmonyOS`，且仓库里没有 `.arkui-x/` 目录 ——
**ArkUI-X 对本项目零收益，只会多一个必须配置的 SDK 依赖**。

修复方式（3 个文件）：

```diff
# hvigor/hvigor-config.json5
-  "dependencies": { "@ohos/hvigor-ohos-arkui-x-plugin": "4.26.1" }
+  "dependencies": {}

# hvigorfile.ts
-export { AppTasksForArkUIX } from '@ohos/hvigor-ohos-arkui-x-plugin';
+import { appTasks } from '@ohos/hvigor-ohos-plugin';
+export default { system: appTasks, plugins: [] }

# entry/hvigorfile.ts
-export { HapTasks } from '@ohos/hvigor-ohos-arkui-x-plugin';
+import { hapTasks } from '@ohos/hvigor-ohos-plugin';
+export default { system: hapTasks, plugins: [] }
```

**3️⃣ 分支代码落后于本文档描述** —— 见开头「版本差异须知」。
合并版工程（18 页面 / 登录 / 智能体网格 / 104 项自检）尚未推送到远端。

---

## 团队与赛事信息

| 项 | 内容 |
|---|---|
| 参赛赛道 | 2026 中国高校计算机大赛 · 人工智能创意赛 · 鸿蒙赛道 · **Agent 创新方向** |
| 团队 | 暗影骑士王们（武汉理工大学） |
| 包名 / 版本 | `com.zhixue.mate` · 1.0.0 (versionCode 1000000) |
| 目标平台 | HarmonyOS SDK 6.1.1(24) |
| 复赛提交截止 | 2026-09-30 24:00 |
| 竞赛官网 | https://developer.huawei.com/home/C4-AI |

## 许可

本项目基于 [MIT License](LICENSE) 开源，Copyright (c) 2026 Ziheng Xu。

---

<div align="center">

**它不是「带 AI 功能的学习应用」，而是一个会把判断讲清楚的 Agent：**

首屏只给你一个最优解，每个终点页都告诉你下一步，
而它给出的每一个数字，都能在界面上逐行展开、在接口里复现、在断网时依然成立。

</div>
