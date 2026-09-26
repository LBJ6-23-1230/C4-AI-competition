# 关于「题目为什么一直是那几个」与「DDL 上传是否有影响」

> 面向：前端同学 / 测试同学
> 结论基于对源码的逐层核对，不是推测。涉及的每一处都标注了文件与行号。

---

## 一、直接回答两个问题

### ❓ 「题目一直是那几个，是不是因为我没上传 DDL？」

**不是。上传 DDL 不影响出题。**

`/api/v1/exercises/**` 出题接口**完全不读取**你上传的课程/DDL 数据。
实测核对：`app/api/exercises.py` 里没有任何一处引用 `user_data` / `courses` /
`homeworkDDLs`。

### ❓ 「想要通过接入的大模型给出适合的题目？」

**目前出题不走大模型，这是刻意的设计。**

选题由确定性代码完成（`app/tools/exercise_tools.py` 的 `select_exercises`）：
只按「知识点 + 难度」过滤题库，取前 N 题，并**剥离答案字段**。
没有随机、没有大模型参与。

> 原因见第四节 —— 这是本项目最重要的技术主张。

---

## 二、那「一直是那几个」的真正原因

三处叠加，缺一不可：

### 1. 前端把题集 ID 写死了

`app/entry/src/main/ets/cache/DemoSnapshot.ets:14`

```ets
static readonly EXERCISE_SET_ID: string = 'set-demo-binary-tree-001';
```

练习页直接用它，且**不传任何筛选参数**：

`app/entry/src/main/ets/pages/ExercisePractice.ets:16`

```ets
@State setId: string = DemoSnapshot.EXERCISE_SET_ID;
```

### 2. 后端对「无筛选条件的演示题集」恒定返回同一批

`app/api/exercises.py:87`

```python
_DEMO_EXERCISES = select_exercises(_EXERCISE_BANK, "binary-tree-postorder", count=3)
```

`app/api/exercises.py:120-124`

```python
has_filter = bool(knowledge_point_id or difficulty or excluded_ids)
if set_id == DEMO_EXERCISE_SET_ID and not has_filter:
    exercises = _DEMO_EXERCISES[:count] if count_explicit else _DEMO_EXERCISES
else:
    exercises = select_exercises(_EXERCISE_BANK, knowledge_point_id, difficulty, count, excluded_ids)
```

→ **没有筛选条件时直接返回 `_DEMO_EXERCISES`**，所以永远同样 3 题。

### 3. 实测确认

```
GET /api/v1/exercises/set-demo-binary-tree-001
    → 3 题：二叉树前序 / 中序 / 后序遍历     ← 每次都是这三题
```

这三题就是题库里 `binary-tree-postorder` 知识点的前 3 条，
**与 DDL、与登录状态、与画像都无关**。

---

## 三、题集其实有 35 题 / 6 个知识点（筛选是通的）

题库：`server/zhixue-agent-server/data/question_bank.json`，**35 题**：

| 知识点 | 题数 |
|---|---|
| `binary-tree-postorder` 二叉树后序遍历 | 8 |
| `binary-tree-search` 二叉搜索树 | 5 |
| `binary-tree-traversal` 二叉树遍历基础 | 5 |
| `graph-algorithm` 图算法 | 5 |
| `algorithm-complexity` 算法复杂度先修 | 5 |
| `recursion-basics` 递归基础 | 7 |

**带筛选参数时会动态选**，实测：

```
GET /api/v1/exercises/set-demo-binary-tree-001?knowledgePointId=graph-algorithm&count=3
    → 3 题：BFS 通常使用哪种数据结构？
            DFS 通常使用哪种数据结构？
            无权图最短路径常用什么算法？
```

**能力已经有了，只是 App 界面没暴露这个入口**（练习页固定不传参）。

---

## 四、为什么出题刻意不用大模型

这是本项目最重要的技术主张：

> **大模型只负责「理解意图」与「生成自然语言」；
> 所有业务计算 —— 判分、掌握度、优先级、重规划 —— 一律留在确定性代码里。**

具体到出题与判分：

| 环节 | 谁来做 | 为什么 |
|---|---|---|
| 理解用户意图 | 大模型 | 自然语言是模型擅长的 |
| **选题** | **确定性代码** | 要能复现：同一条件同一题集 |
| **判分** | **确定性代码** | 分数必须可复现、可核对 |
| **掌握度更新** | **确定性代码** | `+29 / +16 / +4 / −4` 是固定规则 |

**如果让大模型出题/判分，会出现：**

- 同一份答案，今天判 66.67、明天判 60，**无法复现**
- 演示基线（`66.67` / 掌握度 `42→58`）**对不上文档与 PPT**
- 答案会随生成结果变化，**没法提前验证**
- 题集下发的**答案保护**（剥离 `answerKey`）会失效

所以固定演示题集是**有意为之**，为的是让「演示数字可复现」这一条立得住。
它同时也是我们在 PPT 第 7 页讲的那个技术点的证据。

---

## 五、DDL 上传到底影响什么（不是没用，是用在别处）

上传课程 / 作业 DDL 后，前端会把数据带进**对话请求**：

`app/entry/src/main/ets/services/AgentBridge.ets:82-86`

```ets
userDataObj['courses'] = appState.courses;
userDataObj['homeworkDDLs'] = appState.homeworkDDLs;
userDataObj['isDataImported'] = appState.isDataImported;
```

后端只在**对话层与计划层**使用（`app/agent/chat_llm.py:397` 的 `_user_data`）：

| 影响 | 不影响 |
|---|---|
| ✅ 对话回复里"你最该做的事"的依据 | ❌ 练习页出题 |
| ✅ 学习计划的任务来源 | ❌ 判分规则 |
| ✅ 主动提醒（DDL 临近） | ❌ 掌握度算法 |

**一句话**：DDL 影响「**今天该做什么**」，不影响「**练什么题**」。

---

## 六、因此，测试时应该这样判断「后端有没有通」

因为题目固定，**不能靠"题目变了"判断后端是否连通**。可靠的判断方式：

| 方式 | 怎么做 | 可靠的信号 |
|---|---|---|
| **① 看后端窗口** ⭐ | 后端启动的那个终端 | App 每发一次请求就滚出一行日志；**没有新行 = 没连上** |
| **② 对话页状态行** | 打开对话页 | 显示「**在线 · AI学习助手**」= 已连上；显示「连接超时或网络不可用」= 没连上 |
| **③ 接口环境页自检** | 工具 → 接口环境 → 点「检测当前计划接口」 | 显示「连接成功：**真实后端**返回 Plan V1」= 真后端；显示「**Fixture** 返回」= 离线 |
| **④ 判分数字** | 练习页做 2 对 1 错并提交 | 得到 **66.67** 且掌握度 **42 → 58** = 后端在算 |

> ⭐ 方式①最直接。后端窗口是"请求有没有到"的唯一权威证据。

---

## 七、⚠️ 最容易踩的坑：离线 Fixture 模式会「粘住」

登录页有一个「**无网络？用离线模式进入**」按钮。

点过一次就切到 Fixture，而且**这个设置会持久化**
（`app/entry/src/main/ets/api/ApiEnvironmentStore.ets:35` 写入 Preferences）——
**重启 App 也不会自动恢复在线**。

### 现象

- 题目固定（走内置 Fixture 数据）
- 后端窗口**收不到任何请求**
- 容易误判成「后端坏了」或「没上传 DDL」

### 怎么切回来

1. App → 右上角「**工具**」→「**接口环境**」页
2. 看按钮文字：
   - 显示 `✓ 当前：离线 Fixture` → **现在就是离线**
   - 点「**使用真 Agent 后端（5000）**」切回
3. 页面下方确认显示：
   ```
   当前模式：真实后端
   当前地址：http://10.0.2.2:5000
   ```
4. 点「**检测当前计划接口**」→ 应显示「连接成功：真实后端返回 Plan V1」

### 地址别填错

| 环境 | 地址 |
|---|---|
| **模拟器** | `http://10.0.2.2:5000`（默认已是这个） |
| 真机（同一 WiFi） | `http://<开发机局域网IP>:5000` |
| 本机浏览器 | `http://127.0.0.1:5000` |

> 真机**不能**用 `10.0.2.2` —— 那是模拟器专用的宿主映射地址。

---

## 八、测试前必做（检查清单）

- [ ] **后端已启动**，窗口里能看到 `监听地址 : http://0.0.0.0:5000`
- [ ] 后端窗口**没有关**
- [ ] App「接口环境」页显示的是「**使用真 Agent 后端**」（不是「✓ 当前：离线 Fixture」）
- [ ] 模拟器用 `10.0.2.2:5000` / 真机用开发机局域网 IP
- [ ] 点一次「检测当前计划接口」，确认返回的是「真实后端」而不是「Fixture」
- [ ] 测试过程中留意后端窗口是否有新日志滚出

---

## 九、如果确实想「按上传的 DDL 出题」

技术上可行，但需要改动，且有取舍：

| 方案 | 做法 | 优点 | 代价 |
|---|---|---|---|
| **A. 前端加换题入口** | 练习页传 `knowledgePointId` / `difficulty`（后端已支持，实测可用） | 改动小，不动后端 | 仍从固定题库选，不是"生成" |
| **B. 后端加随机抽样** | 对演示题集支持 `?refresh=1` | 观感上"题会变" | **破坏演示基线复现性** |
| **C. 让大模型生成题目** | 按 DDL 内容生成新题 | 最贴合"AI 出题"的说法 | **判分不可复现、答案无法预先验证、需重做答案保护** |

**建议**：演示用方案 A（安全，不影响基线）。
方案 C 与项目的核心技术主张冲突，如果要做，只能作为**独立的"AI 出题"演示分支**，
不能替换掉现有的可复现练习主链。

---

*本文由项目维护。所有结论均核对自 V2 提交版源码，标注了文件与行号，可逐条复核。*
