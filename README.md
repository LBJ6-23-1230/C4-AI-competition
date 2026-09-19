# 知学 Mate · HarmonyOS 前端

本分支是「知学 Mate」的 HarmonyOS / ArkTS 前端工程。应用面向大学生学习场景，提供 Agent 对话、学情画像、诊断练习、动态学习计划、学习搭子、专注计时、主动提醒和桌面卡片等功能。

> 这是 `frontend` 分支，不包含后端源码。联调时需要另行启动符合 `api-contract-v0.3` 的统一 Agent 后端。

## 当前状态

- ArkTS 主 HAP 已通过真实 Hvigor 构建。
- ohosTest 测试 HAP 已通过编译。
- 模拟器回归基线：`40 / 40` 通过。
- API 契约：`contracts/openapi.json`，版本 `api-contract-v0.3`。
- 默认连接真实后端；无网络时可在「接口环境」页切换到离线 Fixture。

## 主要能力

| 能力 | 说明 |
|---|---|
| Agent 对话 | 支持文字和图片输入、意图卡片、本地规则/大模型来源标识 |
| 工作流与 Trace | 展示 Agent、工具调用、状态版本和证据链 |
| 诊断练习 | 拉取题集、提交答案、显示判分及掌握度变化 |
| 动态计划 | 展示 Plan 版本、任务时长变化和调整理由 |
| 主动服务 | 基于考试、学习间隔、掌握度和 DDL 生成提醒与桌面卡片 |
| 账号与离线演示 | 支持注册、恢复登录、游客体验和 Fixture 演示 |

## 工程结构

```text
.
├── AppScope/                         # 应用级配置与资源
├── entry/
│   ├── src/main/ets/
│   │   ├── api/                     # HTTP 客户端、契约 DTO、登录态与 Fixture
│   │   ├── cache/                   # 工作流和业务缓存
│   │   ├── components/              # 复用组件
│   │   ├── data/                    # 应用状态与演示数据
│   │   ├── pages/                   # 18 个注册页面
│   │   ├── services/                # Agent、语音、通知和卡片服务
│   │   └── viewmodels/              # 结构化业务流程
│   ├── src/test/                       # Hypium 单元测试
│   └── src/ohosTest/                   # 设备端测试入口
├── contracts/                        # OpenAPI 契约与离线 Fixture
├── deliverables/                     # 线框图等交付物
├── docs/                             # 前端测试与验收资料
└── tools/                            # 构建、契约和模拟器回归脚本
```

## 开发环境

- DevEco Studio，HarmonyOS SDK `6.1.1(24)`
- Node.js 使用 DevEco Studio 内置版本
- 应用 Bundle Name：`com.zhixue.mate`
- 后端默认端口：`5000`

`local.properties` 是本机文件，不会提交。用 DevEco Studio 打开工程后，请确认其中的 SDK 和 Node.js 路径指向当前开发机。

## 运行

1. 用 DevEco Studio 打开仓库根目录，不要只打开 `entry/`。
2. 执行 Sync，并在 Signing Configs 中配置调试签名。
3. 启动模拟器或连接真机。
4. 运行 `entry` 模块。
5. 首次启动可注册、使用演示身份，或跳过登录进入离线演示。

后端地址可在 App 的「接口环境」页修改并持久化：

| 环境 | baseUrl |
|---|---|
| 模拟器 | `http://10.0.2.2:5000` |
| 真机 | `http://<开发机局域网 IP>:5000` |
| 本机调试 | `http://127.0.0.1:5000` |

## 构建与验证

也可以使用 DevEco Studio 内置 Hvigor 在命令行构建：

```powershell
& '<DevEco Studio>\tools\hvigor\bin\hvigorw.bat' --no-daemon `
  -p product=default -p module=entry@default -p buildMode=debug assembleHap

& '<DevEco Studio>\tools\hvigor\bin\hvigorw.bat' --no-daemon `
  -p product=default -p module=entry@ohosTest -p buildMode=debug assembleHap
```

运行契约静态验证：

```powershell
.\tools\validate_contract.ps1
```

已连接 HarmonyOS 模拟器或真机时，运行 40 项回归测试：

```powershell
.\tools\run_ohos_regression.ps1
```

未配置签名时会生成 `entry-default-unsigned.hap`；正式安装和交付前需在 DevEco Studio 中配置签名。

## 联调契约

前端对后端的核心要求：

- 聊天层与 `/api/v1/**` 结构化工作流由同一 `baseUrl` 提供。
- 请求契约版本为 `api-contract-v0.3`。
- 错误响应使用 `{ errorCode, message, details }`。
- 演示身份的 `userId` 为 `demo-user`。
- 聊天响应的 `llmUsed` 可用于区分真实大模型输出与本地规则兜底。

详细路径和 DTO 以 [contracts/openapi.json](contracts/openapi.json) 为准。
