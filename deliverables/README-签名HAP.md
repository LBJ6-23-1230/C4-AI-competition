# 签名 HAP 交付说明

> 生产日期：**2026-09-22 17:00**
> **无需真机即可产出** —— 全程未连接任何设备
>
> ⚠️ 本文件已随 2026-09-22 的重新构建更新。
> 上一版（09-21 23:35）不含之后的修复，已作废。

---

## 一、交付物

| 项 | 值 |
|---|---|
| 文件 | `deliverables/知学Mate-signed.hap` |
| 大小 | **2,301 KB**（2,356,187 字节） |
| SHA256 | `94FF0A383209194B…`（`Get-FileHash -Algorithm SHA256` 可复算） |
| 构建产物路径 | `app/entry/build/default/outputs/default/entry-default-signed.hap` |
| 包名 | `com.zhixue.mate` |
| 版本 | 1.0.0 |
| 签名 | release 证书 + release Profile，有效至 **2029-09-21** |

### 本版相对上一版（09-21）包含的修复

| 修复 | 内容 |
|---|---|
| 卡片描述空白 | 后端 `build_card()` 补 `summary` 字段（前端一直在读它） |
| 大屏布局错位 | 登录页 `constraintSize` 从 `Scroll` 移到内容列；平板/2in1 上文字不再被推到右缘截断 |
| 两个对话图标 | 语音改 `sys.symbol.mic`、拍照改 `sys.symbol.camera` |
| 验证码登录不可用 | 前端校验器补 `send-code` / `verify-code` 两条路由 |
| 冷启动登录态失效 | `EntryAbility` 串行化恢复（原先并行导致每次冷启动都被踢回登录页） |
| 死代码炸弹 | `AuthClient.register()` 的 `phone` 提为必填参数 |
| 其他 | 空 `answers` 不再无理由扣分；跨账号数据隔离；前端 7 项 P2 |

---

## 二、签名验证结果（DevEco 自带工具独立校验）

```
Find Hap Signing Block success, version: 3, block count: 3
profile type is: release
verify codesign success
Write certificate chain success!
verify: Verify success
verify-app success
```

| 验证项 | 结果 |
|---|---|
| 签名块 | ✅ `Hap Signing Block version 3`，块数 3 |
| Profile 类型 | ✅ **release** |
| 摘要/代码签名校验 | ✅ `verify codesign success` |
| 整体校验 | ✅ **`verify-app success`** |
| 侧载安装 | ✅ **已在模拟器实测** `install bundle successfully` → 正常进入应用 |

---

## 三、证书链（签名工具输出的权威结果）

| # | Subject | 有效期 | SHA256（证书指纹） |
|---|---|---|---|
| 0 | `Huawei CBG Root CA G2` | 2020-03-16 ~ 2049-03-16 | `DF:21:A3:C0:9F:…:DF:3A:37` |
| **1** | **`许梓恒(2044548867596244609)\Release`** | **2026-09-21 ~ 2029-09-21** | **`13:A3:03:8D:C6:…:8B:7A:86:00`** |
| 2 | `Huawei CBG Developer Relations CA G2` | 2020-07-09 ~ 2030-07-07 | `0D:AA:8A:96:5B:…:97:58:71:80` |

> **#1 是真正的签名者证书。** 该值已登记在 AGC
> （项目设置 → 常规 → SHA256证书/公钥指纹），
> 与同证书的**公钥指纹** `36:EC:7B:02:…:FC:8D:04:B8` 一并登记，
> 覆盖 AGC 可能采用的任一种比对口径 —— 这是华为账号一键登录能通过授权的前提。

---

## 四、签名配置（可复现）

`app/build-profile.json5` 的 `signingConfigs`（由 DevEco GUI 写入，密码为加密串）：

| 字段 | 值 |
|---|---|
| name | `default`（与 `products[0].signingConfig` 一致 ✅） |
| storeFile | `E:/zhixue-signing/zhixue-debug.p12` |
| keyAlias | `zhixue-debug` |
| signAlg | `SHA256withECDSA` |
| profile | `E:/zhixue-signing/zhixue-release-profileRelease.p7b` |
| certpath | `E:/zhixue-signing/zhixue-release.cer` |

**关键操作**：必须**取消勾选**「自动生成签名文件」。
自动签名会尝试去 AGC 新建 Profile → 新建 Profile 必须绑定设备 → 报
"缺少设备导致无法新建profile文件"。我们用的是 AGC 上已建好的发布 Profile，不需要它新建。

> 也可用命令行绕开 GUI：
> `& 'tools/sign_hap.ps1'`

---

## 五、签名验证通过的**含义**

### ✅ 已经确定

- HAP **已正确签名**，摘要与代码签名校验通过
- 签名所用证书与发布 Profile **配套**，且**已在 AGC 登记正确指纹**
- 该 HAP **格式完整、可侧载安装、可用于提交**（模拟器已实测安装并运行）

### ⚠️ 仍需真机才能确认的部分

| 项 | 说明 |
|---|---|
| **HarmonyOS NEXT 真机侧载** | 模拟器已装成功；NEXT 真机需复验（本项目无可用 NEXT 真机） |
| 华为账号一键登录 | 配置已全部对齐（见 `docs/29`），缺真机做端到端联调 |
| 小艺口令 | 意图已注册，缺真机 |

> ⚠️ **不能在这台 HarmonyOS 4.2 手机上装**：项目要求 `compatibleSdkVersion 6.1.1(24)`（API 24），
> 而 4.2 是基于 AOSP 的旧平台、调试桥为 ADB（非 HDB），平台不通。

### 对比赛提交的影响

规程 §3 附加评分原文：

> 实际可演示的 **HAP 文件**/源代码文件/演示系统、作品上架，附加评分越高

**"有签名 HAP 文件"这一条件已满足**，不要求评审现场安装。安装验证仍建议做（为了演示视频和答辩），但不是提交的前置条件。

---

## 六、提交物命名（照抄规程）

| # | 材料 | 命名 |
|---|---|---|
| 1 | 作品说明文档 PDF | `01-作品说明文档+暗影骑士王们.pdf` |
| 2 | 演示视频 MP4 | `02-演示视频+暗影骑士王们.mp4` |
| 3 | 演示 HAP/源代码 zip | `03-知学Mate+暗影骑士王们.zip` |

> zip 内建议同时放 `hap/知学Mate-signed.hap` 与源码目录，README 说明。

---

## 七、复现步骤（若需重新签名）

```powershell
# 方式一：DevEco GUI
#   File > Project Structure > 签名配置
#   → 取消勾选「自动生成签名文件」
#   → 按 §四 的表填写
#   → Build > Build Hap(s)

# 方式二：命令行（不依赖 GUI）
& 'E:\C4-liantiao\liantiao5\tools\sign_hap.ps1'

# 验证（注意：只支持 -inFile / -outCertChain / -outProfile 三个参数，
#       多传 -outProof 会 exit=1 且不产出文件）
& 'D:\DevEco\DevEco Studio\jbr\bin\java.exe' -jar `
  'D:\DevEco\DevEco Studio\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar' `
  verify-app -inFile '<signed.hap>' -outCertChain 'chain.cer' -outProfile 'profile.p7b'
```
