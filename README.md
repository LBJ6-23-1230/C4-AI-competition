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

## ⚠️ 先读这一段：代码在 `backend` / `frontend` 分支，`main` 只有文档

本仓库的 `main` 分支**目前只放 LICENSE 与本说明文档**，实际的源码分布在另外两个分支：

| 分支 | 内容 | 文件数 |
|---|---|---|
| **`main`** | 本 README（项目总说明） | 2 |
| **`backend`** | Python Agent 后端（`zhixue-agent-server/`）+ 契约 + 后端文档 | 79 |
| **`frontend`** | ArkTS 前端完整工程 + 契约 + 前端文档 + 联调工具 | 147 |

**评审老师 / 想跑起来的人，请按下面这一条命令取到完整工程：**

```bash
git clone -b frontend --single-branch https://github.com/LBJ6-23-1230/C4-AI-competition.git zhixue-mate
cd zhixue-mate
powershell -ExecutionPolicy Bypass -File tools\start_dev.ps1   # 启动后端
# 再用 DevEco Studio 打开本目录
```

> **为什么这样组织**：前后端由两名成员并行开发，分分支可以各自独立演进、互不阻塞。
> `frontend` 分支内已包含一份可直接运行的后端（`backend/`），
> 因此**只克隆 `frontend` 就能跑通全部演示**，无需再拉 `backend`。
>
> 📌 **待办（团队内部）**：复赛要求提交「项目运行所需的**所有工程文件**」。
> 建议将前后端合并后的单一工程推送为 `main`，让默认分支即为完整可运行版本。
> 详见下方「仓库结构现状与待办」。

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

「今天最该学什么」不是一个黑盒判断，而是五个因子加权求和：

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

## 5 层 Agent 工作流

| 层 | 职责 | 界面落点 |
|---|---|---|
| **1 输入层** | 汇集课程表、考试时间、作业 DDL、错题图片、用户目标、空闲时间 | 首页「感知摘要」 |
| **2 理解层** | 识别课程紧迫度、错题知识点与错误类型、评估目标差距 | 错题分析页 |
| **3 判断层** | **挑出最优学习任务**（五因子）、判断薄弱程度、搭子匹配可行性 | 首页「今日最优任务」卡 |
| **4 行动层** | 生成学习建议、错题补强建议、学习标签、搭子匹配结果 | 建议页 / 搭子页 / 计划页 |
| **5 输出层** | 输出今日学习卡、错题诊断卡、搭子卡、协同计划、学习复盘 | **每个终点页的「接下来」卡** |

第 5 层是本次迭代的重点：**每个页面都必须告诉用户下一步做什么**，
而不是把数据摊开就结束。

---

## 技术架构

```
┌──────────────────────────────────────────────────────────────┐
│              HarmonyOS ArkTS 前端（19 页面）                   │
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
| 前端 | ArkTS / ArkUI 声明式 UI · HarmonyOS SDK **6.1.1(24)** · 19 页面 |
| 后端 | Python **3.12** + Flask 3.x · 单进程单端口 |
| 大模型 | 通义千问 `qwen-vl-plus`（DashScope 兼容模式，支持多模态识图） |
| 契约 | `api-contract-v0.3`（前后端 `openapi.json` 逐字节一致） |
| 持久化 | 仓储层已抽象（`Repository` 协议），当前实现为 JSON 单文件 |
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

## 核心演示流程（可复现的数值）

这是最该演示的一条链，全程可验证：

| 步 | 操作 | 看到什么 |
|---|---|---|
| 1 | 打开 App | 首页「今日最优任务：二叉树后序遍历 **45 分钟** · 考试还有 5 天」 |
| 2 | 展开「为什么是它」 | 五行因子贡献值 + 综合优先级 |
| 3 | 点「开始专注」 | 进入专注设置，任务已预填 |
| 4 | 「更多 → 错题分析」拍一道题 | 知识点、错误类型、3 条补强建议（配 Key 时为真实 Qwen-VL 识别） |
| 5 | 点「做 3 道同类专项题」 | 进入练习页 |
| 6 | 答案选 **A / B / A** 并提交 | **得分 66.67%** · 掌握度 **42 → 58** |
| 7 | 继续下滑 | 计划 **V1 → V2**，任务时长 **45 / 15** |
| 8 | 点「再练一组同类题」 | 页面内重开一轮 |
| 9 | 点「看 Agent 决策过程」 | `secretary → exercise → assessment`，3 个工具全部留痕 |

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

## 项目结构

```
zhixue-mate/
├── AppScope/                     应用级配置（包名 com.zhixue.mate）
├── entry/                        ArkTS 主模块
│   └── src/main/ets/
│       ├── pages/                19 个页面
│       ├── components/           6 个组件（含 FollowUpCard「下一步」卡）
│       ├── viewmodels/           6 个 ViewModel
│       ├── api/                  接口层（含 ApiDefaults 单一真源、Auth* 登录）
│       ├── services/             AgentBridge（聊天）/ LocalAgentService（离线规则）
│       └── data/ · models/ · cache/ · utils/
├── backend/                      Python 后端（frontend 分支内附完整副本）
├── contracts/openapi.json        前后端唯一接口契约 v0.3
├── docs/                         设计与分析文档
├── tools/                        启动、联调自检、回归脚本
├── deliverables/ui_wireframes/   UI 线框图
├── build-profile.json5           HarmonyOS 构建配置（SDK 6.1.1(24)）
└── README.md
```

### 界面清单（19 页）

| 分类 | 页面 |
|---|---|
| **入口** | `Login` 登录 · `Index` 首页（四标签：首页 / 计划 / 记录 / 我的）· `Account` 我的 |
| **对话** | `ChatMain` 对话主页（文字 + 图片 + 6 类意图快捷按钮） |
| **学习闭环** | `StudySuggestion` 建议 → `WrongQuestion` 错题 → `ExercisePractice` 练习 → `StudyTags` 画像 → `StudyPlan` 计划 |
| **专注** | `FocusSetup` → `FocusTimer` → `FocusResult` · `LearningHistory` |
| **社交 / 复盘** | `PartnerMatch` 学习搭子 · `ReviewSummary` 学习复盘 |
| **审计 / 调试** | `AgentTrace` 决策轨迹 · `ApiEnvironment` 接口环境 · `CourseImport` 课程与作业 |

---

## 工程设计上的几个取舍（供评审参考）

| 取舍 | 选择 | 理由 |
|---|---|---|
| **鉴权** | 可选 Bearer，不是门禁 | 评审现场一个过期 token 不该让整个 App 不可用；不带 token 按游客身份处理，**演示基线完全不受影响**（有 31 项断言守着） |
| **登录方式** | 免密昵称注册，不做密码体系 | 本工程没有需要密码保护的数据；生产化路径是接入 AGC 认证服务 |
| **降级策略** | 显式标注，不静默伪装 | 缺 Key 时回复会写明"以上由本地确定性规则生成，不是大模型输出" |
| **离线 Fixture** | 保留，且判分规则与后端**逐条对齐** | 现场网络不可控，必须能离线演示；判分不能因为是离线就失真 |
| **持久化** | JSON 单文件 | 演示零运维；仓储层已抽象，换 SQLite/AGC **只需改一行** |

---

## 已知边界（诚实声明）

| 范围 | 状态 |
|---|---|
| 后端逻辑、契约、判分、Agent 循环 | ✅ 真实 HTTP 实跑验证（104/104） |
| 后端单元测试 / 连续回归 | ✅ `90 passed` / `10/10 runs passed` |
| 前端编译 | ✅ `BUILD SUCCESSFUL`，可产出 HAP |
| **前端交互（设备上点击流程）** | ⚠️ **未完成设备验证** —— 编译通过 ≠ 交互正确 |
| 真实 LLM 调用 / 图片 OCR | ⚠️ 需配置 `DASHSCOPE_API_KEY` 后验证 |
| HAP 签名安装 | ⚠️ 仅缺签名配置 |
| 服务卡片 / 后台代理提醒 / 语音 / 位置 | ❌ 尚未实现（Agent 赛道「主动服务」的下一步） |
| 手机号验证码登录（AGC） | ❌ 尚未实现 |
| 多设备适配（平板 / PC） | ❌ 尚未实现 |

---

## 仓库结构现状与待办

### 现状

```
main       ── LICENSE + 本 README（无源码）
backend    ── Python 后端（79 文件）
frontend   ── ArkTS 前端完整工程（147 文件，内含后端副本与联调工具）
```

### 三个已知问题（团队内部待处理）

**1️⃣ 默认分支看不到代码** —— 评审打开仓库首页只能看到一个 83 字节的占位 README，
容易误判为"仓库是空的"。**建议将合并后的完整工程推送为 `main`。**

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

**3️⃣ 各分支 README 版本不一致** —— `frontend` 分支的 README 是较完整的旧版说明
（仍写着 ArkUI-X，与实际不符）；`backend` 分支的 README 是占位内容。
**本 README 是唯一权威版本**，分支文档仅作历史参考。

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

首页只给你一个最优解，每个终点页都告诉你下一步，
而它给出的每一个数字，都能在界面上逐行展开、在接口里复现、在断网时依然成立。

</div>
