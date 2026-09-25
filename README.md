<div align="center">

# 知学 Mate（ZhiXue Mate）

**会主动找你的 AI 学习搭子**

HarmonyOS 原生应用 · ArkTS 前端 + Python Agent 后端

[![Platform](https://img.shields.io/badge/Platform-HarmonyOS-1F4E79?style=flat-square)](https://developer.huawei.com/consumer/cn/)
[![SDK](https://img.shields.io/badge/SDK-6.1.1(24)-2563EB?style=flat-square)](https://developer.huawei.com/consumer/cn/)
[![Frontend](https://img.shields.io/badge/Frontend-ArkTS-10B981?style=flat-square)]()
[![Backend](https://img.shields.io/badge/Backend-Python%203.12%20%2B%20Flask-B45309?style=flat-square)]()
[![Contract](https://img.shields.io/badge/Contract-api--contract--v0.3-0F766E?style=flat-square)]()
[![Tests](https://img.shields.io/badge/Tests-327%20passed-16A34A?style=flat-square)]()
[![Integration](https://img.shields.io/badge/Integration-95%2F95-16A34A?style=flat-square)]()

**2026 中国高校计算机大赛 · 人工智能创意赛 · 鸿蒙赛道 · Agent 创新方向**

团队：**暗影骑士王们**（武汉理工大学）｜复赛提交截止：**2026-09-30 24:00**

</div>

---

## 📦 这就是最终提交版本 V2

> **本仓库 `main` 分支 = 提交版 V2**，可直接提交。
>
> | 要交的东西 | 在哪 |
> |---|---|
> | **提交压缩包**（含签名 HAP + 全量源码 + 作品说明文档） | **`知学Mate+暗影骑士王们.zip`** |
> | 作品说明文档（必交） | `01-作品说明文档/` |
> | 演示视频（必交，待录） | `02-演示视频/` |
> | 签名 HAP（加分） | `hap/知学Mate-signed.hap` |
>
> **先读这三份**：[`仓库结构说明.md`](仓库结构说明.md)（各目录是什么）·
> [`README-提交说明.md`](README-提交说明.md)（怎么跑）·
> [`提交清单与待办.md`](提交清单与待办.md)（还差什么）
>
> 三轮独立 Bug 审计报告：[`项目文档/28-全项目Bug审计报告.md`](项目文档/28-全项目Bug审计报告.md)
>
> 已验证：**`pytest 333 passed`** + **联调 98/98** + **演示基线零漂移**
> （66.67 / 全错 0.0 / 42→58 / [30,30]→[45,15]）

---

## ⚠️ 先读这一段：目录布局

**仓库根就是提交版结构**（V2 快照）；完整开发历史在 `dev-history` 分支。

| 路径 | 内容 |
|---|---|
| `知学Mate+暗影骑士王们.zip` | **打包好的提交压缩包**（338 条目） |
| `hap/知学Mate-signed.hap` | 签名 HAP 副本（release，有效至 2029-09-21） |
| `01-作品说明文档/` `02-演示视频/` | 必交材料 |
| `app/` | **HarmonyOS ArkTS 前端**（19 页面 / 5 智能体 / 服务卡片 / 意图框架 / 分布式接续） |
| `server/zhixue-agent-server/` | **Python Agent 后端**（单进程同时提供自然语言层与工作流层） |
| `contracts/openapi.json` | 契约真源（`app/contracts/` 下是逐字节一致的镜像） |
| `integration/run_liantiao5.py` | 一键联调（契约闸门 + 测试 + 95 项 HTTP + 归档） |
| `tools/` | 构建、契约校验、大屏布局检查、运行态数据检查等脚本 |
| `03-演示文件与源代码/` | 开发工作区里源码的原样副本（与根目录内容相同） |
| `项目文档/` | 28 份技术文档（含审计报告、分布式报告、真机说明） |
| `实证材料/` | 46 份实跑证据（联调汇总、界面截图、大屏布局证据） |

**想跑起来：**

```bash
git clone https://github.com/LBJ6-23-1230/C4-AI-competition.git zhixue-mate
```

> **`dev-history` 分支**：完整开发历史（47 个提交，含每一轮修复与验证记录），
> 供追溯用；文件内容与 `main` 一致。`main` 是单一提交的提交快照。
>
> **`backend` / `frontend` 两个分支是更早期的历史留档，不要用** ——
> 它们是前后端分离时代的版本，`frontend` 分支还带 ArkUI-X 插件
> （会导致 DevEco Sync 失败），且不含登录、验证码、华为账号、服务卡片。

### 📌 当前版本状态（V2）

| 项 | 结果 |
|---|---|
| 契约一致性闸门 | ✅ **逐字节一致**（`api-contract-v0.3`，**110,417 B** / 33 端点 / 51 schema / 15 错误码） |
| 后端单元测试 | ✅ **327 项全绿** |
| HTTP 实跑联调 | ✅ **98 / 98（100%）**，退出码 **0** |
| 演示基线 | ✅ **零漂移**（66.67 / 全错 0.0 / 42→58 / [30,30]→[45,15] / [1,2]） |
| ArkTS 编译 | ✅ **全量重编 0 编译错误**，产物 2.25 MB |
| 签名 HAP | ✅ `verify-app success`，AGC 指纹已对齐 |
| 安装运行 | ✅ 模拟器 `install bundle successfully` |
| 全场景分布式 | ✅ 双端 `joined session` 实测建立 |
| 代码审计 | ✅ 三轮独立审计 34 项，已修 **28 项**（含 5 个 P0） |
| 交付包数据洁净 | ✅ 无 `.env` / 证书 / 运行态数据 |

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
这不是宣传语 —— 后端单测与联调脚本里都有对应断言，且**在 live 模式下基线数值同样不变**。

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

## 界面结构（19 页面 · 四标签）

### 设计原则：对话用于表达，能力页用于发现

应用**启动先过登录页**（无登录态时），登录后**直接落在对话页**。
四个标签各回答一个问题，**同一个页面不会在两个标签下重复出现**。

| 标签 | 回答的问题 | 内容 |
|---|---|---|
| **对话** | 我直接说需求 | 问候引导 + 大输入框 + 6 个意图快捷 chip（名字与落地页一致） |
| **智能体** | 它替我做什么 | **5 张智能体卡**（认知职能），点击弹出该智能体的能力入口面板 |
| **学习** | 我要处理什么 | 上传作业与 DDL · 任务安排（开始专注 / 课程与作业清单） |
| **我的** | 我是谁 / 我学得怎么样 | 账号卡 · 学习数据 · 学习复盘 · 搭子与协同 · 开发调试 |

### 完整页面清单（19 个）

| 分类 | 页面 |
|---|---|
| **入口** | `Login` 登录 · `Index` 工作台 · `ChatMain` 对话 · `Account` 我的 |
| **学习闭环** | `StudySuggestion` → `WrongQuestion` → `ExercisePractice` → `StudyTags` → `StudyPlan` |
| **专注** | `FocusSetup` → `FocusTimer` → `FocusResult` · `LearningHistory` |
| **社交 / 复盘** | `PartnerMatch` 学习搭子 · `ReviewSummary` 学习复盘 |
| **知识库 / 审计** | `KnowledgeBase` 知识库 · `AgentTrace` 决策轨迹 · `ApiEnvironment` 接口环境 · `CourseImport` 课程与作业 |

> **每个终点页都有「接下来」卡**（`FollowUpCard` 组件）：错题诊断完 → 做同类专项题；
> 练习判分完 → 再练一组或看更新后的画像；看完画像 → 按薄弱点开始练习。
> Agent 的第 5 层「输出层」必须落在界面上，而不是把数据摊开就结束。

### 5 个智能体（认知职能，不是功能页）

| 智能体 | 分类 | 职责 | 可直达 |
|---|---|---|---|
| **诊断智能体** | 学情诊断 | 定位薄弱点与错误根因 | 错题诊断 · 学情画像 |
| **规划智能体** | 路径规划 | 决定先学什么、排多长 | 今日学习建议 · Agent 学习计划 |
| **练习智能体** | 推送练习 | 推送针对性练习并判分 | 专项练习 |
| **测评智能体** | 效果评估 | 验证学习是否有效 | 学习复盘 |
| **秘书智能体** | 总控编排 | 判断「下一步该叫哪个智能体」 | Agent 决策过程 |

**秘书智能体统筹另外四个** —— 这张花名册就是把后端 `app/agents/`
（`diagnosis` / `planner` / `exercise` / `assessment` / `secretary`）搬到界面上给评委看。

---

## 鸿蒙特性（复赛创新性主战场）

| 特性 | 实现 | 位置 |
|---|---|---|
| **服务卡片** | 桌面卡片直接显示"今天该学什么" | `entryformability/LearningCardFormAbility.ets` · `widget/LearningCard.ets` |
| **意图框架（小艺口令）** | 「开始学习」/「查看今日学习计划」拉起对应页面 | `insightintent/StartFocusIntent.ets` · `QueryTodayPlanIntent.ets` |
| **本地通知 / 主动提醒** | DDL 临近主动提醒，点击直达应用 | `services/ProactiveSurfaceService.ets` · `ProactiveViewModel.ets` |
| **语音输入** | 语音转文字接入对话 | `services/VoiceInputService.ets` |
| **华为账号一键登录** | AGC `client_id` + 证书指纹，`@kit.AccountKit` | `services/HuaweiAccountService.ets` |
| **令牌加密落盘** | AES-256-GCM + 资产库，失败降级明文并如实提示 | `api/TokenCipher.ets` |
| **大屏适配** | 断点 + 限宽居中 | `utils/DeviceLayout.ets` |

> **意图框架产物已验证**：编译产物 `module.json` 含 `"hasInsightIntent": true`，
> `insight_intent.json` 被重新生成为 `extractInsightIntents` 结构，0 个 InsightIntent 编译错误。
> 仅有「对真机说小艺口令」这一步待设备验证。

---

## 技术架构

```
┌──────────────────────────────────────────────────────────────┐
│              HarmonyOS ArkTS 前端（19 页面）                   │
│   AgentBridge ──┐                                            │
│   ViewModels  ──┼──► AgentApiClient（唯一 HTTP 入口）          │
│   ProactiveVM ──┘                                            │
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
│     agent/proactive · experiments · auth · knowledge-bases    │
│     └ 真 Agent 循环：secretary → exercise → assessment         │
│     └ 确定性工具：grade_exercise / update_mastery / replan      │
│     └ trace 留痕（3 事件 / 3 agent / 3 tool），不含思维链         │
└──────────────────────────────────────────────────────────────┘
```

### 技术栈

| 层 | 选型 |
|---|---|
| 前端 | ArkTS / ArkUI 声明式 UI · HarmonyOS SDK **6.1.1(24)** · **19 页面** |
| 后端 | Python **3.12** + Flask 3.x · 单进程单端口 |
| 大模型 | 通义千问 · 识图 `qwen-vl-max`（`qwen-vl-plus` 免费额度已实测耗尽）· 决策 `qwen-plus` |
| 语义检索 | `text-embedding-v3` + 关键词/标签混合（`hybrid:semantic+keyword+tag`） |
| 契约 | `api-contract-v0.3`（前后端 `openapi.json` **逐字节一致**） |
| 持久化 | 仓储层已抽象（`Repository` 协议）· JSON 单文件 **或 SQLite**（环境变量一行切换） |
| 登录 | 免密昵称 + 长期 token · **验证码登录** · **华为账号一键登录** · 鉴权可选不做门禁 |
| 测试 | 后端 **295** 个单元测试 · 联调自检 **95** 项断言 · 前端 14 个单测文件 |

---

## 快速开始

### 前置条件

- **DevEco Studio** + **HarmonyOS SDK 6.1.1(24)**
- **Python 3.12+**（工程使用 `str | Path` 语法，3.8 无法运行）

### 1. 启动后端

```powershell
cd server\zhixue-agent-server

# 首次：准备 Python 环境
uv venv ..\..\.venv --python 3.12
uv pip install --python ..\..\.venv\Scripts\python.exe -r requirements.txt

# 启动
..\..\.venv\Scripts\python.exe run.py
```

看到 `监听地址 : http://0.0.0.0:5000` 即成功。

**可选但强烈建议** —— 配置大模型，激活错题拍照识别：

```powershell
Copy-Item .env.example .env
notepad .env      # 填入 DASHSCOPE_API_KEY=sk-xxxx
```

> 不配 Key 也能完整跑通演示：聊天层会降级为确定性规则，
> **并在回复里显式标注"不是大模型输出"** —— 不伪装、不静默兜底。

### 2. 打开前端

1. DevEco Studio 打开 `app/` 目录
2. **Sync and Refresh Project**
3. `File > Project Structure > 签名配置` → **取消勾选「自动生成签名文件」**，
   手动填 `.p12` / `.p7b` / `.cer`（详见 `项目文档/24-签名材料核验报告.md`）
   > ⚠️ 自动签名会让 `appid` 随机化，打断小艺与华为账号的授权关系
4. 选 `entry` 模块运行到模拟器 / 真机

### 3. 联调地址怎么填（最容易踩的坑）

| 运行环境 | baseUrl |
|---|---|
| 本机浏览器 / 桌面预览 | `http://127.0.0.1:5000` |
| HarmonyOS 模拟器 | `http://10.0.2.2:5000` |
| HarmonyOS 真机（同一 WiFi） | `http://<开发机局域网IP>:5000` |

**不必改代码**：App 内「接口环境」页可直接填写并持久化。
无网络时也可一键切「离线 Fixture」，用本机数据完整演示（判分规则与后端一致）。

---

## 登录与身份

登录定位是「**Agent 的身份锚点**」，不是门禁。

| 入口 | userId | 需要后端 | 用途 |
|---|---|---|---|
| **一键体验**（主按钮） | `demo-user` | ❌ | 评委 / 演示永远点这个，零摩擦 |
| **昵称注册** | 服务端下发 `u-xxxx` | ✅ | 建立自己的画像，学习记录归到自己名下 |
| **手机号验证码登录** | 服务端下发 | ✅ | 真实用户体系（未配短信时界面**如实显示"开发模式回显"**） |
| **华为账号一键登录** | AGC openID | ✅ | 鸿蒙原生账号能力 |
| **跳过 → 离线模式** | `demo-user` | ❌ | 自动切 Fixture，断网也能进 |

**四条关键设计**（都是为了让登录不伤害演示）：

1. **游客优先，绝不硬门禁** —— 未登录用约定的 `demo-user`，可跑通全部页面。
2. **演示基线零影响** —— `demo/reset` 只作用于 `demo-user`，`mastery 42 / Plan V1 [30,30] / √√× → 66.67 → 58` 逐项不变。
3. **鉴权可选，不是门禁** —— 不带 token 按游客处理；带无效 / 过期 token **降级为游客而不是 401**。
4. **令牌加密落盘** —— `TokenCipher` 用 AES-256-GCM + 系统资产库；
   若加密不可用则**降级为明文并置 `encryptionDegraded()`**，由账号页如实提示，不会把登录打挂。

### 接口

```
POST   /api/v1/auth/register         {nickname, grade?}  → {user, token, expiresAt}   201
POST   /api/v1/auth/login            {userId, token}     → {user, token, expiresAt}
POST   /api/v1/auth/logout           (Bearer)            → {status}
GET    /api/v1/auth/me               (Bearer)            → {user}
DELETE /api/v1/auth/account          (Bearer)            → {status: deactivated}
POST   /api/v1/auth/send-code        {phone}             → {resendAfterSeconds, devCode?}
POST   /api/v1/auth/verify-code      {phone, code}       → {user, token, expiresAt}
```

---

## 核心演示流程（可复现的数值）

| 步 | 操作 | 看到什么 |
|---|---|---|
| 1 | 启动 App | 进入**登录页**；点「跳过登录，用演示身份进入」零摩擦进主界面 |
| 2 | 落地页 | **对话页**（`ChatMain`）——标题「知学 Mate」，无历史消息时显示问候引导 |
| 3 | 切「智能体」标签 | **5 张智能体卡**（诊断/规划/练习/测评/秘书），含 6 类筛选 |
| 4 | 点「规划智能体」卡 | 弹出该智能体的能力面板，选「今日学习建议」 |
| 5 | 看到今日最优任务 | 「二叉树后序遍历 **45 分钟** · 考试还有 5 天」 |
| 6 | 展开「为什么是它」 | 五行因子贡献值 + 综合优先级 |
| 7 | 切「学习」标签 → 开始专注 | 进入专注设置，任务已预填 |
| 8 | 「诊断智能体 → 错题诊断」拍一道题 | 知识点、错误类型、3 条补强建议（配 Key 时为真实 Qwen-VL 识别） |
| 9 | 点「做 3 道同类专项题」 | 进入练习页（`ExercisePractice`） |
| 10 | 答案选 **A / B / A** 并提交 | **得分 66.67%** · 掌握度 **42 → 58** |
| 11 | 继续下滑 | 计划 **V1 → V2**，任务时长 **45 / 15** |
| 12 | 「秘书智能体 → Agent 决策过程」 | `secretary → exercise → assessment`，3 个工具全部留痕 |

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
python integration\run_liantiao5.py --port 5097
# 退出码 0 = 全部通过；原始输出写入 evidence\
```

| 环节 | 内容 |
|---|---|
| ⓪ 契约闸门 | 真源与镜像逐字节一致（`api-contract-v0.3`，110,417 B） |
| ① 后端单元测试 | **333 passed / 0 failed** |
| ② HTTP 实跑联调 | **98 / 98（100%）** |
| ③ 演示基线 | 6 项数值全部命中，零漂移 |
| ④ 数据洁净 | 三份数据文件前后**逐字节不变** |

**live 模式**（真模型接通，换一套断言集合）：

```powershell
python integration\run_liantiao5.py --port 5097 --llm-mode live
```

---

## 工程设计上的几个取舍（供评审参考）

| 取舍 | 选择 | 理由 |
|---|---|---|
| **鉴权** | 可选 Bearer，不是门禁 | 评审现场一个过期 token 不该让整个 App 不可用；**演示基线完全不受影响** |
| **登录方式** | 游客优先 + 多种真实登录并存 | 演示零摩擦，同时不放弃真实账号能力 |
| **降级策略** | 显式标注，不静默伪装 | 缺 Key 时回复会写明"以上由本地确定性规则生成，不是大模型输出" |
| **离线 Fixture** | 保留，判分规则与后端**逐条对齐** | 现场网络不可控，必须能离线演示；判分不能因为是离线就失真 |
| **持久化** | JSON 默认，SQLite 可选 | 演示零运维；仓储层已抽象，换后端**只需改一个环境变量** |
| **首页形态** | 对话优先 + 能力页分离 | Agent 的价值是"你直接说它就能做"，而不是让人先读一遍功能清单 |
| **签名方式** | **手动签名**（不用自动签名） | 自动签名会让 `appid` 随机化，与小艺/华为账号侧登记的 appid 不一致 → 授权异常 |

---

## 已知边界（诚实声明）

| 范围 | 状态 |
|---|---|
| 后端逻辑、契约、判分、Agent 循环 | ✅ 真实 HTTP 实跑验证（98/98） |
| 后端单元测试 | ✅ `333 passed` |
| 契约一致性 | ✅ 逐字节一致（110,417 B） |
| 真模型 live 模式 | ✅ 11 轮 × 95/95，基线零漂移 |
| 前端编译 | ✅ `BUILD SUCCESSFUL`，**`[ERROR]` 级 0 条 / ArkTS 编译错误 0 条** |
| **签名 HAP** | ✅ **已产出并通过独立验签**（发布证书 + 发布 Profile，摘要校验 `true`，`SignHap` 耗时 4.6 s） |
| **本机模拟器** | ✅ **已打通**（`Pura 90` 等 4 实例，API 24；`tools/start_emulator.ps1` 一键启动） |
| **签名 HAP 安装** | ✅ **模拟器实测 `install bundle successfully`，`EntryAbility` 进入 `FOREGROUND`** |
| 模拟器内网络 | ✅ `ping 10.0.2.2` 0% 丢包（宿主后端用 `http://10.0.2.2:5000`） |
| **真机安装 / 交互** | ⚠️ **未做** —— 模拟器已通，但真机行为仍需实测 |
| 小艺口令 / 华为账号一键登录 | ⚠️ **需真机** —— 华为账号登录在模拟器上必然失败（错误码 `1001500001`，界面已如实提示） |
| `TokenCipher` 冷启动 | 🟢 可在模拟器验证（不再依赖真机） |
| 意图框架 `hasInsightIntent` 产物 | ✅ 已验证为 `true`；仅"对真机说口令"待验 |
| `@ohos.router` → `Navigation` 迁移 | ❌ 未迁移（61 处，API 24 仍可用，仅标记废弃） |
| 其余 18 个页面的响应式落地 | 🟢 可在模拟器边改边看（仅示范了 `Login`，能力在 `utils/DeviceLayout.ets`） |
| 全场景分布式（`distributedDataObject`） | 🟢 **可行**：开两个模拟器实例即可演示 —— 标题写"全场景"而内容零分布式，是答辩最可能被追问的点 |
| `414` 统一 JSON | ⚠️ **实测不生效**：超长请求行在 WSGI 解析层即被拒，返回 Werkzeug HTML 而非应用 JSON 处理器（详见 `docs/19` A11） |
| 上架应用市场 | ❌ 未上架（发布证书与 Profile 已就绪） |

---

## 拿到代码后仍需自己做的一步

**配置 HarmonyOS SDK 路径** —— `local.properties` 属于机器本地配置，按惯例不入库。克隆后二选一：

```properties
# 方式 A：在 app/ 目录新建 local.properties
sdk.dir=D:\\DevEco\\DevEco Studio\\sdk
nodejs.dir=D:\\DevEco\\DevEco Studio\\tools\\node
```

```powershell
# 方式 B：设系统环境变量
setx DEVECO_SDK_HOME "D:\DevEco\DevEco Studio\sdk"
```

然后用 DevEco Studio 打开 `app/` → **Sync and Refresh Project**。

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
