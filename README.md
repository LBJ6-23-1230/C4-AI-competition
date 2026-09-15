# 知学搭子（ZhiXue Mate）· C4-AI 完整整合项目

**C4-AI 大赛「暗影骑士王们」队项目仓库** —— 一款面向大学生学习场景的 HarmonyOS / ArkUI-X AI 学习搭子应用原型。整合前端 ArkTS 工程与后端 Python Flask + LLM（通义千问）服务，围绕"AI 驱动的个性化学习辅助"形成完整可演示闭环。

---

## 项目简介

**知学搭子**是一个运行在 HarmonyOS 上的智能学习助手，核心理念是让 AI Agent 主动感知用户的学习环境（课程、考试、作业 DDL、错题记录），通过 **5 层 AI Agent 工作流**（输入层 → 理解层 → 判断层 → 行动层 → 输出层）生成可执行的个性化学习方案。

项目支持**双模式运行**：
- **纯前端模式**：基于 `LocalAgentService` 的本地 Agent 逻辑，无需后端即可跑通完整演示流程
- **联机模式**：启动 Flask 后端，接入通义千问 `qwen-vl-plus` 大模型，实现真实 AI 对话与智能分析

### 核心能力

| 能力 | 说明 |
|---|---|
| **AI 对话交互** | ChatMain 对话主页，支持文字 + 图片输入，6 种意图自动识别，后端 LLM 生成回复 |
| **全局 AI 浮标** | 所有页面右下角可拖拽 AI 浮标，点击弹出内联对话小窗，无需跳转即可在任何页面与 AI 助手对话 |
| **学习建议生成** | 根据考试紧迫度、近期复习状态、知识薄弱点综合评分，自动推荐今日最优学习任务 |
| **错题智能诊断** | 拍照上传错题，Agent 识别知识点、判断错误类型（概念混淆/计算错误/审题不清/知识盲区）、生成补强建议和学习标签 |
| **知识画像雷达图** | 基于错题分析自动生成薄弱标签和优势标签，Canvas 五边形雷达图可视化知识掌握水平，红/蓝/浅蓝三色标记薄弱/已掌握/进行中维度 |
| **学习搭子匹配** | 四大因子（课程一致 +40、目标一致 +25、知识互补 +20、时间重叠 +5~20）智能匹配最佳学习伙伴 |
| **协同学习计划** | Agent 自动生成三阶段（互讲概念 → 互测练习 → 错题复盘）协同流程，支持"发起协同专注" |
| **专注模式** | 普通/严格两种模式，支持倒计时（30/60分钟/自定义）和正计时，完整的设置→计时→结果→记录流程 |
| **文件数据导入** | 支持 CSV/JSON 格式导入真实课程表和作业 DDL，Agent 自动识别数据来源并基于真实数据分析 |
| **学习记录与复盘** | 专注时长统计、课程累计、完成率趋势、连续学习天数、Agent 反馈与下一步建议 |

### 演示主线

项目围绕统一的演示故事线设计：**小明**（用户）正在备考**数据结构**期末考试（目标 80+），薄弱知识点为**二叉树遍历**和**递归理解**，空闲时间为每晚 20:00-22:00。通过 AI Agent 分析，匹配到最佳学习搭子**小红**（知识互补、时间重叠于 21:00-22:00），生成协同学习计划并完成专注学习。

---

## 技术架构

### 整体分层

```
┌─────────────────────────────────────────────────────────┐
│                  13 个 ArkTS 页面                         │
│  对话主页 │ 首页 │ 学习建议 │ 错题分析 │ 知识画像 │ 搭子匹配  │
│  学习计划 │ 课程导入 │ 专注设置 │ 专注计时 │ 专注结果       │
│  学习记录 │ 学习复盘                                      │
├─────────────────────────────────────────────────────────┤
│              AgentBridge (后端API桥接)                    │
│         LocalAgentService (5层Agent工作流)               │
├─────────────────────────────────────────────────────────┤
│           AppState (全局单例状态管理)                      │
├─────────────────────────────────────────────────────────┤
│  AgentModels │ ChatModels │ MockData │ FileParser        │
├─────────────────────────────────────────────────────────┤
│     组件库: RadarChart │ ChatBubble │ AIFloatButton      │
├─────────────────────────────────────────────────────────┤
│     HarmonyOS SDK 6.1.1(24) / ArkUI-X                   │
└─────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────┐
│            Python Flask 后端 (端口 5000)                  │
│  agent_routes.py: 意图识别 → 6 路子Agent → LLM 生成      │
│  LLM: 通义千问 qwen-vl-plus (阿里云 DashScope)           │
└─────────────────────────────────────────────────────────┘
```

### 5 层 Agent 工作流

这是本项目的核心设计理念，模拟人类学习助教的思考过程：

| 层级 | 名称 | 职责 | 核心方法 |
|---|---|---|---|
| **第1层** | 输入层 (Input) | 汇集课程表、考试时间、作业 DDL、错题图片、用户目标、空闲时间 | `collectInputData()` |
| **第2层** | 理解层 (Understanding) | 识别课程紧迫度、错题知识点与错误类型、评估学习目标差距 | `analyzeExamUrgency()`, `analyzeWrongQuestion()`, `understandGoal()` |
| **第3层** | 判断层 (Judgment) | 判断最优学习任务优先级、知识薄弱点严重程度、搭子匹配可行性 | `judgeOptimalTask()`, `judgeWeaknesses()`, `judgeMatchFeasibility()` |
| **第4层** | 行动层 (Action) | 生成学习建议、错题补强建议、学习标签、搭子匹配结果 | `generateStudySuggestions()`, `matchPartner()`, `matchBestPartner()` |
| **第5层** | 输出层 (Output) | 输出今日学习卡、错题诊断卡、学习搭子卡、协同学习计划、学习复盘 | `generateDailyLearningCard()`, `generateReviewSummary()` |

工作流状态通过 `AppState.workflowContext` 实时追踪，页面可展示各层完成状态。

### 搭子匹配算法（4 因子模型）

```
总分 = 课程一致(+40) + 目标一致(+25) + 知识互补(+20) + 时间重叠(+5/+10/+15)

知识互补判定：
  - 双方互相帮助（用户强项∩候选弱项 ≠ ∅ 且 用户弱项∩候选强项 ≠ ∅）：+20
  - 单向互补：+10
  - 无互补关系：0

时间重叠分数（取最大重叠段）：
  - ≥60分钟：+15
  - ≥30分钟：+10
  - >0分钟：+5
```

---

## 项目结构

```
C4-AI-project-main/
├── AppScope/                             # 应用级配置与全局资源
│   ├── app.json5                         #   包名 com.zhixue.mate、版本 1.0.0
│   └── resources/                        #   应用图标、启动图、字符串资源
├── entry/                                # 主应用模块（所有业务代码）
│   └── src/main/ets/
│       ├── entryability/
│       │   └── EntryAbility.ets          # 应用入口（加载 pages/Index）
│       ├── pages/                        # 13 个 ArkTS 页面（详见下方）
│       ├── components/                   # 可复用 UI 组件
│       │   ├── RadarChart.ets            #   知识画像五边形雷达图（Canvas 2D 绘制）
│       │   ├── ChatBubble.ets            #   对话气泡组件
│       │   └── AIFloatButton.ets         #   全局可拖拽 AI 浮标 + 弹出对话小窗
│       ├── services/                     # 业务服务层
│       │   ├── AgentBridge.ets           #   后端 API 桥接 + 本地意图关键词匹配
│       │   ├── ChatNavigation.ets        #   对话页面路由导航
│       │   ├── LocalAgentService.ets     #   5层Agent工作流核心（Python→ArkTS改写）
│       │   └── FileParserService.ets     #   文件解析服务（CSV/JSON课程与DDL导入）
│       ├── data/                         # 数据层
│       │   ├── AppState.ets              #   全局单例状态管理（Agent工作流状态+数据导入）
│       │   └── MockData.ets              #   演示模拟数据（用户/课程/候选人/错题/DDL/徽章）
│       ├── models/                       # 类型定义
│       │   ├── AgentModels.ets           #   完整Agent工作流接口（80+类型定义）
│       │   ├── ChatModels.ets            #   对话消息/卡片/意图等类型定义
│       │   └── LearningFlowData.ets      #   页面路由配置与演示流程数据
│       └── utils/                        # 工具类
│           ├── DateHelper.ets            #   日期辅助（真实日历日期计算）
│           └── Model3DRenderer.ets       #   3D模型渲染器
├── backend/                              # Python Flask 后端服务
│   ├── app.py                            #   Flask 入口（端口 5000）
│   ├── agent_routes.py                   #   核心路由：意图识别 + LLM 调用 + 对话管理
│   ├── services.py                       #   搭子匹配/时间重叠/学习建议工具函数
│   ├── services_master.py                #   重构版服务层（用户/课程/错题 CRUD）
│   ├── requirements.txt                  #   Python 依赖（flask, openai 等）
│   ├── .env                              #   环境变量（API Key, 模型配置）
│   ├── .env.example                      #   环境变量模板
│   ├── prompts/                          #   7 个 Prompt 模板文件
│   │   ├── MainAgentPrompt.txt           #     意图识别 Prompt
│   │   ├── AnalyzeWeaknessPrompt.txt     #     薄弱分析 Prompt
│   │   ├── AnalyzeWrongPrompt.txt        #     错题分析 Prompt
│   │   ├── GetSuggestionPrompt.txt       #     学习建议 Prompt
│   │   ├── MatchPartnerPrompt.txt        #     搭子匹配 Prompt
│   │   ├── QueryTasksPrompt.txt          #     任务查询 Prompt
│   │   └── UpdateProfilePrompt.txt       #     信息更新 Prompt
│   ├── mock_users.json                   #   用户模拟数据
│   ├── mock_courses.json                 #   课程模拟数据
│   ├── mock_candidates.json              #   候选人模拟数据
│   ├── mock_wrong_questions.json         #   错题模拟数据
│   └── history.json                      #   对话历史持久化
├── docs/superpowers/specs/               # 设计文档
│   ├── 2026-07-14-focus-mode-design.md
│   └── 2026-07-15-focus-mode-differentiation-design.md
├── deliverables/ui_wireframes/            # UI 线框图
├── tools/
│   └── generate_ui_wireframe_doc.py      # UI线框图生成脚本
├── build-profile.json5                   # HarmonyOS 构建配置（SDK 6.1.1(24)）
├── oh-package.json5                      # 依赖管理
├── hvigorfile.ts                         # 构建入口
└── .arkui-x/                             # ArkUI-X 跨平台壳工程（Android/iOS）
```

---

## 页面详解（13 页完整功能）

### 1. 对话主页 `ChatMain.ets`
AI 对话交互入口。用户可通过文字或图片与 Agent 交流，6 个意图快捷按钮（今日建议/薄弱诊断/错题分析/匹配搭子/查任务/更新信息）一键触发。对话通过 `AgentBridge` 发送到 Flask 后端，LLM 生成回复后渲染为聊天气泡和结构化卡片。支持从对话卡片一键跳转到对应功能页面。

### 2. 首页 `Index.ets`
学习状态总览中心（Hub-and-Spoke 架构的 Hub）。展示 Agent 感知状态、今日学习概览卡片、**学习模式**与**专注模式**双入口。Agent 提醒以对话式文案呈现，底部显示 5 层工作流完成进度。"今日概览"显示优先任务、今日专注分钟数和一条提醒。

### 3. 今日学习建议 `StudySuggestion.ets`
Agent 基于课程紧迫度（考试倒计时）+ 复习状态 + 知识薄弱点 + DDL 紧迫度综合打分（0-100），生成分级建议：
- **≥80 分**：高优先级，推荐补强薄弱知识点，建议 45 分钟
- **40-79 分**：中优先级，系统复习重点章节，建议 30 分钟
- **<40 分**：低优先级，常规复习，建议 20 分钟

支持一键"立即专注"将当前建议任务预填入专注设置页。

### 4. 错题分析 `WrongQuestion.ets`
拍照/选图上传错题 → Agent 自动诊断。根据图片特征返回 4 种分析变体（模拟真实 AI 识别不同题目）：
- **概念混淆**（二叉树遍历/递归调用）
- **知识盲区**（图算法 BFS/DFS）
- **计算错误**（BST/AVL 平衡旋转）
- **概念混淆**（哈希表/冲突解决）

每种分析返回：课程 → 知识点（含置信度）→ 错误类型 → 根因 → 3 条补强建议 → 学习标签。

### 5. 知识画像 `StudyTags.ets`
基于错题分析结果，以 **Canvas 五边形雷达图**可视化展示用户的知识掌握水平。红色标记薄弱维度，蓝色标记已掌握维度，浅蓝色标记进行中维度。下方展示薄弱知识点卡片（含严重程度：严重/一般）和优势知识点标签云。标签数据同时用于搭子匹配中的知识互补计算。

### 6. 搭子匹配 `PartnerMatch.ets`
展示 4 因子匹配详情：
- **课程一致**：同修数据结构 (+40)
- **学习目标一致**：均以期末 80+ 为目标 (+25)
- **知识能力互补**：小明擅长图算法可帮助小红的薄弱项，小红擅长递归理解可帮助小明 (+20)
- **空闲时间匹配**：20:00-22:00 与 21:00-23:00 重叠 60 分钟 (+15)

最终得分 100 分，匹配最佳搭子**小红**，显示匹配因子明细和公共空闲时段。

### 7. 协同学习计划 `StudyPlan.ets`
Agent 自动生成 30 分钟三阶段协同学习流程：
1. **互讲概念**（10分钟）：小明讲解图算法，小红讲解递归理解
2. **互测练习**（10分钟）：互相出题检测对方的薄弱知识点
3. **错题复盘**（10分钟）：共同回顾今日错题，记录易错点

支持"发起协同专注"一键创建专注任务。同时展示 Agent 生成的周计划（包含决策追溯 `AgentDecisionTrace`）。

### 8. 课程与作业 `CourseImport.ets`
双标签页设计：
- **课程列表**：展示当前课程（名称、考试日期、倒计时、优先级、复习状态）
- **导入数据**：支持从文件系统选择 CSV/JSON 文件或手动粘贴内容导入真实课程和作业 DDL

`FileParserService` 自动检测格式（JSON/CSV），表头支持中英文，自动计算剩余天数和推断优先级。导入后 Agent 所有分析切换为基于真实数据。

### 9. 专注设置 `FocusSetup.ets`
配置专注任务参数：
- **课程**：从课程列表选择
- **任务**：手动输入或从学习建议/课程任务/协同计划预填
- **时长**：30分钟 / 60分钟 / 自定义（1-180分钟）/ 正计时
- **模式**：普通专注（可暂停）/ 严格专注（无暂停，退出需二次确认）
- **任务来源**：标注 agent / manual / course / collaborative

### 10. 专注计时 `FocusTimer.ets`
深色沉浸界面，倒计时/正计时实时更新。
- **普通模式**：可暂停、继续、确认完成、提前退出
- **严格模式**：无暂停按钮、无导航返回、退出需二次确认并记录 `interrupted`
- 进度条可视化，显示当前课程和任务标题

### 11. 专注结果 `FocusResult.ets`
结算页展示：专注方式、计时方式、计划时长 vs 实际时长、暂停/中断次数、完成率、用户自评（完成/部分完成/未完成）。Agent 根据完成率给出差异化反馈与下一步建议。

### 12. 学习记录 `LearningHistory.ets`
展示今日专注分钟数、课程累计时长、完成率、连续学习天数、最近七天趋势和任务列表。

### 13. 学习复盘 `ReviewSummary.ets`
学习完成后总结：完成任务列表、复习知识点汇总、学习搭子信息、获得徽章、能力提升描述、Agent 推荐的下一步行动。

---

## 后端服务

### 启动方式

```bash
cd backend
pip install -r requirements.txt    # 首次安装依赖
python app.py                       # 启动服务，默认端口 5000
```

### 环境配置（`.env`）

```env
DASHSCOPE_API_KEY=sk-xxxxxxxx      # 通义千问 API Key
LLM_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
LLM_MODEL=qwen-vl-plus             # 支持 qwen-plus / qwen-vl-plus / deepseek-chat
```

### API 接口

前后端正式字段以 `contracts/openapi.json`（`api-contract-v0.2`）为准；`contracts/fixtures/` 提供固定核心链的逐接口样例。

| 方法 | 路径 | 说明 |
|---|---|---|
| `POST` | `/api/agent/chat` | 主对话接口，接受 `{"message": "...", "image": "base64..."}` 返回 `{"reply": "...", "intent": "...", "card": {...}}` |
| `GET` | `/api/agent/health` | 健康检查，返回 LLM 配置状态 |
| `GET` | `/api/agent/history` | 获取对话历史 |
| `DELETE` | `/api/agent/history` | 清空对话历史 |
| `GET` | `/api/agent/user-data` | 获取用户数据快照（用户/课程/候选人/错题） |
| `POST/GET` | `/api/v1/workflows...` | 创建并查询诊断工作流 |
| `GET` | `/api/v1/profile/{userId}` | 获取版本化学习画像与证据 |
| `GET` | `/api/v1/plans/current` | 获取当前权威学习计划 |
| `GET/POST` | `/api/v1/exercises/{setId}...` | 获取练习并提交评估 |
| `GET` | `/api/v1/plans/{planId}/diff` | 获取重规划差异 |
| `GET` | `/api/v1/traces/{traceId}` | 获取 Agent 决策轨迹 |
| `POST` | `/api/v1/demo/reset` | 将契约演示状态重置为 Profile/Plan V1 |

`/api/v1` 当前是状态化契约演示实现，可通过真实 HTTP 完整跑通 42 → 58 → Plan V2，并校验契约版本与幂等提交；它不等同于生产评分或生产推荐算法。

### 6 意图 Agent 系统

```
用户消息 → MainAgentPrompt (意图识别)
         ├── query_tasks       → QueryTasksPrompt
         ├── analyze_weakness  → AnalyzeWeaknessPrompt
         ├── get_suggestion    → GetSuggestionPrompt
         ├── match_partner     → MatchPartnerPrompt
         ├── analyze_wrong     → AnalyzeWrongPrompt (支持图片)
         ├── update_profile    → UpdateProfilePrompt
         ↓
      保存 history.json → 返回 reply + card
```

前端只有在用户明确选择“离线 Fixture”时才使用本地意图与固定导航卡片。真实后端模式请求失败会显示明确错误并保留输入，不会静默回退或伪装成真实 Agent 结果。

---

## ArkTS 改写说明

原始 `master` 分支的 Python 服务（`backend/services.py`，7 个函数）**已全部改写为 ArkTS/TypeScript**，位于 `entry/src/main/ets/services/LocalAgentService.ets`。

### Python → ArkTS 映射表

| Python (`services.py`) | ArkTS (`LocalAgentService.ets`) | 改进点 |
|---|---|---|
| `generateStudySuggestions()` | `generateStudySuggestions()` | 增加 DDL 紧迫度因子，优先级分 3 级 |
| `analyzeWrongQuestion()` | `analyzeWrongQuestion()` | 4 种变体分析（原仅 2 种），字段名 Tag→tags |
| `parseTime()` | `parseTime()` (private) | 增加格式校验与 Error 抛出 |
| `formatTime()` | `formatTime()` (private) | 逻辑一致 |
| `getOverlapScore()` | `getOverlapScore()` | 增加数组遍历安全处理 |
| `matchPartner()` | `matchPartner()` | `in` 运算符 → `===` 严格比较，增加 `MatchFactor[]` 明细 |
| `matchBestPartner()` | `matchBestPartner()` | 增加空列表安全检查，返回 `null` 而非 `None` |
| （无） | `hasCommonItem()` (private) | 新增辅助方法 |

### Mock 数据对照

| JSON 文件（`backend/`） | ArkTS 常量（`entry/.../data/MockData.ets`） |
|---|---|
| `mock_users.json` | `mockCurrentUser: UserProfile` |
| `mock_courses.json` | `mockCoursesList: CourseInfo[]`（3门课程） |
| `mock_candidates.json` | `mockCandidates: UserProfile[]`（3位候选人） |
| `mock_wrong_questions.json` | `mockWrongQuestions: WrongQuestionRecord[]`（3道错题） |

### 核心改进

1. **类型安全**：Python 动态类型 → ArkTS interface 完全类型化（80+ 类型定义）
2. **字段名规范**：camelCase 统一（如 `OverlapStart` → `overlapStart`，`Tag` → `tags`）
3. **匹配逻辑改进**：`in` 子串匹配 → `===` 精确比较
4. **错误处理**：`parseTime` 增加格式校验；`matchBestPartner` 增加 null 安全检查
5. **功能扩展**：新增 DDL 考虑、优先级分 3 级、MatchFactor 明细、5 层工作流可视化
6. **LLM 集成**：新增 Flask 后端 + 通义千问大模型，实现真实 AI 对话能力

---

## 文件导入功能

支持从外部文件导入真实课程表和作业 DDL 数据，Agent 自动切换为基于真实数据分析。

### 支持格式

**JSON 格式**：
```json
{
  "courses": [
    { "courseName": "数据结构", "examDate": "2026-07-20", "priority": "高", "studyHours": 2, "status": "近期复习不足" }
  ]
}
```

**CSV 格式**（表头支持中英文）：
```csv
课程名称,考试日期,优先级,学习时长,复习状态
数据结构,2026-07-20,高,2,近期复习不足
```

### 关键特性

- **自动格式检测**：根据首字符自动选择 JSON/CSV 解析器
- **中英文表头兼容**：CSV 表头同时支持 `courseName` 和 `课程名称`
- **智能推断**：未提供优先级/复习状态时，根据天数自动推断
- **模板一键获取**：提供 JSON/CSV 模板
- **数据恢复**：随时可点击"恢复演示数据"回退到模拟数据

---

## 专注模式详解

### 模式对比

| 特性 | 普通专注 | 严格专注 |
|---|---|---|
| 界面风格 | 浅色、"可随时调整节奏" | 深色沉浸、"严格专注进行中" |
| 暂停按钮 | ✅ 可暂停/继续 | ❌ 无暂停 |
| 导航返回 | ✅ 正常返回 | ❌ 不可返回 |
| 提前退出 | 弹窗选择：继续/保存未完成/丢弃 | 二次确认 → 记录 `interrupted` → 进入结算 |
| 完成确认 | 确认弹窗 → 进入结算 | 确认弹窗 → 进入结算 |

### 计时方式

| 方式 | 说明 |
|---|---|
| 30 分钟 / 60 分钟 | 固定倒计时，到点结算 |
| 自定义时长 | 1-180 分钟倒计时 |
| 正计时 | 从 00:00 向上累计，无预设目标 |

### 状态类型

| 状态 | 含义 |
|---|---|
| `completed` | 正常完成（普通模式确认完成） |
| `not_completed` | 普通模式提前保存 |
| `interrupted` | 严格模式退出/中断 |

---

## 本地开发

1. 使用 **DevEco Studio** 打开项目根目录（`C4-AI-project-main/`）。
2. 确认已安装 **HarmonyOS SDK 6.1.1(24)**（`build-profile.json5` 中 `targetSdkVersion` 和 `compatibleSdkVersion`）。
3. 在 DevEco Studio 中执行 **Sync and Refresh Project** 同步依赖。
4. 配置本机签名后，选择 `entry` 模块运行到模拟器或真机。
5. **纯前端模式**：无需后端，直接使用模拟数据跑通全流程演示。
6. **联机模式**：先启动后端 `cd backend && python app.py`，ChatMain 对话页即可通过 LLM 获得真实 AI 回复。

---

## 演示流程

### 主流程（学习模式）
```
对话主页 → 首页 → 今日学习建议 → 错题分析 → 知识画像 → 搭子匹配 → 协同学习计划 → 学习复盘
```

### 专注流程
```
首页（专注模式） → 专注设置 → 专注计时 → 专注结果 → 学习记录
                                                     ↘ 返回首页
```

### 数据导入流程
```
课程与作业（导入标签） → 选文件/粘贴 → 自动解析 → Agent 基于真实数据重算全部建议
```

---

## Git 提交约定

- Word 文档（`*.docx`）只作为本地资料保存，**不提交**到 GitHub。
- `oh_modules/`、`.hvigor/`、`.idea/`、`local.properties` 等本机依赖、缓存和 IDE 配置**不提交**。
- `.codex/`、`.agents/`、临时 skills 目录等 AI 工具配置**不提交**。
- `.preview/`、`build/`、`__pycache__/` 等构建产物目录**不提交**（已在 `.gitignore` 中配置）。
- 阶段性功能稳定后，统一提交并推送到 GitHub。

---

## 设计规范

### 视觉原则
- **主色调**：蓝色 `#2563EB` 作为品牌主色（按钮、链接、强调元素），语义色用于状态区分：红色 `#EF4444`（薄弱/警告）、绿色 `#10B981`（成功/优势）、橙色（提醒）
- **圆角与间距**：统一 12-20vp 圆角、16-20vp 内边距
- **按钮规范**：每页只有一个实心主按钮，其他操作用描边或文字按钮
- **文案风格**：以具体行动表达（如"用 30 分钟理清中序遍历"），避免空泛的技术术语
- **知识画像雷达图**：420×420vp Canvas 五边形，40px 角标签，红/蓝/浅蓝三色数据点标记

### 状态覆盖
所有交互流程均覆盖以下状态：
- **进行中**：正常加载和数据展示
- **成功**：操作完成后的结果反馈
- **无结果/失败**：空数据或错误时的引导提示
- **下一步**：明确的后续操作引导

---

## 项目元信息

| 属性 | 值 |
|---|---|
| 包名 | `com.zhixue.mate` |
| 版本 | 1.0.0 (versionCode: 1000000) |
| 目标平台 | HarmonyOS (SDK 6.1.1(24)) |
| 跨平台 | ArkUI-X (Android/iOS 壳工程) |
| 开发工具 | DevEco Studio |
| 语言 | ArkTS (TypeScript 方言) |
| 后端 | Python 3 + Flask + 通义千问 qwen-vl-plus |
| 大赛团队 | 暗影骑士王们 |
| 最后更新 | 2026-07-22 |
