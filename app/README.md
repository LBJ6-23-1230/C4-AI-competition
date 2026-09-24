# 知学 Mate · HarmonyOS 前端

本目录是「知学 Mate」的 HarmonyOS / ArkTS **前端工程**，位于
`main` 分支的 `app/` 下。应用面向大学生学习场景，提供 Agent 对话、
学情画像、诊断练习、动态学习计划、学习搭子、专注计时、主动提醒、
桌面卡片与**全场景跨设备接续**等功能。

> ⚠️ **关于分支**：工程根目录就是**前后端合并后的完整工程** ——
> 本目录与同级 `server/` 同属 `main` 分支，clone 下来即可一起运行。
> 仓库里的 `frontend` / `backend` 两个**旧分支**是历史留档，**不要用**
> （`frontend` 分支仍带 ArkUI-X 插件会导致 Sync 失败，且不含登录、
> 验证码、华为账号、服务卡片）。

## 当前状态

| 项 | 结果 |
|---|---|
| ArkTS 主 HAP | ✅ 真实 Hvigor 全量构建通过，**0 编译错误** |
| 注册页面 | **19 个**（见 `entry/src/main/resources/base/profile/main_pages.json`） |
| 联调验证 | ✅ **95 / 95**（`integration/run_liantiao5.py`） |
| 后端单元测试 | ✅ **327 passed** |
| 签名 HAP | ✅ `verify-app success`，release Profile 有效至 2029-09-21 |
| 模拟器安装运行 | ✅ `install bundle successfully` → 正常进入应用 |
| API 契约 | `contracts/openapi.json`，版本 `api-contract-v0.3`（与 `app/contracts/` 逐字节一致） |
| 默认数据源 | 连接真实后端；无网络时可在「接口环境」页切换到离线 Fixture |

## 主要能力

| 能力 | 说明 |
|---|---|
| Agent 对话 | 文字与图片输入、意图卡片、大模型/本地规则来源标识 |
| 工作流与 Trace | 展示 Agent、工具调用、状态版本与证据链 |
| 诊断练习 | 拉取题集、提交答案、显示判分与掌握度变化 |
| 动态计划 | 展示 Plan 版本、任务时长变化与调整理由 |
| 主动服务 | 基于考试倒计时、学习间隔、掌握度与 DDL 生成提醒与桌面卡片 |
| **全场景接续** | `DistributedStateService` —— 手机开始专注，平板看到同一任务 |
| 账号体系 | 手机号注册/登录、手机验证码登录、**华为账号一键登录** |
| 离线演示 | 游客体验与 Fixture 演示（无网兜底） |
| 桌面卡片 / 小艺 | 服务卡片与意图框架（`widget/`、`insightintent/`） |
| 多设备形态 | `phone / tablet / 2in1` 三形态声明 + 大屏限宽布局 |

## 工程结构

```text
app/
├── AppScope/                         # 应用级配置与资源
├── entry/
│   ├── src/main/ets/
│   │   ├── api/                     # HTTP 客户端、契约 DTO、登录态与 Fixture
│   │   ├── cache/                   # 工作流和业务缓存
│   │   ├── components/              # 复用组件
│   │   ├── data/                    # 应用状态与演示数据
│   │   ├── pages/                   # 19 个注册页面
│   │   ├── services/                # Agent、语音、分布式、通知与卡片服务
│   │   ├── insightintent/           # 小艺意图框架
│   │   ├── widget/                  # 桌面服务卡片
│   │   ├── utils/                   # 设备形态判断（DeviceLayout）等
│   │   └── viewmodels/              # 结构化业务流程
│   ├── src/test/                    # Hypium 单元测试
│   └── src/ohosTest/                # 设备端测试入口
├── contracts/                        # OpenAPI 契约镜像与离线 Fixture
├── docs/                             # 前端相关文档（与根 docs/ 同步）
└── tools/                            # 契约校验与模拟器回归脚本
```

## 开发环境

- DevEco Studio **6.1.1.125**
- HarmonyOS SDK **`6.1.1(24)`**（API 24）
- Node.js 使用 DevEco Studio 内置版本
- 应用 Bundle Name：`com.zhixue.mate`
- 后端默认端口：`5000`

`local.properties` 是本机文件，不会提交。用 DevEco Studio 打开工程后，
请确认其中的 SDK 与 Node.js 路径指向当前开发机。

> ⚠️ **设备要求**：需 **HarmonyOS NEXT（5.0+）**。本项目
> `compatibleSdkVersion = 6.1.1(24)`，基于 AOSP 的 HarmonyOS 4.x
> 设备（调试桥为 ADB 而非 HDB）**无法安装**。

## 运行

1. 用 DevEco Studio 打开 **`app/` 目录**（不要只打开 `entry/`）。
2. 执行 Sync；在 `File > Project Structure > 签名配置` 中
   **取消勾选「自动生成签名文件」**，手动填 `.p12` / `.p7b` / `.cer`。
   > 自动签名会让 appid 随机化，打断小艺与华为账号的授权关系。
3. 启动模拟器或连接真机。
4. 运行 `entry` 模块。

后端地址可在 App 的「工具 → 接口环境」页修改并持久化：

| 环境 | baseUrl |
|---|---|
| 模拟器 | `http://10.0.2.2:5000` |
| 真机（同一 WiFi） | `http://<开发机局域网 IP>:5000` |
| 本机调试 | `http://127.0.0.1:5000` |

## 构建与验证

用 DevEco Studio 内置 Hvigor 在命令行构建：

```powershell
& '<DevEco Studio>\tools\hvigor\bin\hvigorw.bat' --no-daemon `
  -p product=default -p module=entry@default -p buildMode=debug assembleHap

& '<DevEco Studio>\tools\hvigor\bin\hvigorw.bat' --no-daemon `
  -p product=default -p module=entry@ohosTest -p buildMode=debug assembleHap
```

契约静态验证与设备端回归：

```powershell
.\tools\validate_contract.ps1
.\tools\run_ohos_regression.ps1      # 需已连接模拟器或真机
```

未配置签名时会生成 `entry-default-unsigned.hap`；正式安装与交付前需配好签名。

## 联调契约

前端对后端的核心要求：

- 聊天层与 `/api/v1/**` 结构化工作流由同一 `baseUrl` 提供。
- 请求契约版本为 `api-contract-v0.3`（请求头 `X-API-Contract-Version`）。
- 错误响应统一为 `{ errorCode, message, details }`。
- 演示身份的 `userId` 为 `demo-user`。
- 聊天响应的 `llmUsed` 用于区分真实大模型输出与本地规则兜底
  （前端据此显示来源标签，**绝不把降级结果伪装成模型输出**）。

详细路径与 DTO 以 [contracts/openapi.json](contracts/openapi.json) 为准。
