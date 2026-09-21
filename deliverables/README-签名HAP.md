# 签名 HAP 交付说明

> 生产日期：2026-09-21 23:35
> **无需真机即可产出** —— 全程未连接任何设备

---

## 一、交付物

| 项 | 值 |
|---|---|
| 文件 | `deliverables/知学Mate-signed.hap` |
| 大小 | **2,287,008 字节**（2,233.4 KB） |
| SHA256 | `F4BF5D9EC7700FF4E9D8E1BC0FA726D1F617C8B7222BC6D8A6D28960D6784A42` |
| 构建产物路径 | `app/entry/build/default/outputs/default/entry-default-signed.hap` |
| 包名 | `com.zhixue.mate` |
| 版本 | 1.0.0 |

---

## 二、签名验证结果（独立第三方验证）

用 DevEco 自带 `hap-sign-tool.jar verify-app` 独立校验：

```
Digest verify result: true, DigestAlgorithm: SHA-256
Write certificate chain success!
verify: Verify success
verify-app success
```

| 验证项 | 结果 |
|---|---|
| 摘要校验 | ✅ `true` |
| 构建日志 `SignHap` 耗时 | ✅ **4 s 607 ms**（上一轮 1 ms = 被跳过） |
| 文件大小增量 | ✅ +54,836 B 签名数据 |
| 包内 Profile 与原 `.p7b` | ✅ SHA256 **逐字节相同** `E2775DBD...9A1E` |

---

## 三、证书链（签名工具输出的权威结果）

| # | Subject | 有效期 | SHA256 |
|---|---|---|---|
| 1 | `许梓恒(2044548867596244609)\Release` | 2026-09-21 ~ 2029-09-21 | `13:A3:03:8D:...:7A:86:00` |
| 2 | `Huawei CBG Developer Relations CA G2` | 2020-07-09 ~ 2030-07-07 | `0D:AA:8A:96:...:71:80` |
| 3 | `Huawei CBG Root CA G2` | — | — |

> **证书 #1 的 SHA256 = 离线分析得出的 `release.cer[2]`** ——
> 之前的离线推断（Profile 绑定的是链中第 3 段）被签名工具独立证实。

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

## 五、签名验证通过的**含义**与**未验证的部分**

### ✅ 已经确定

- HAP **已正确签名**，摘要校验通过
- 签名所用证书与发布 Profile **配套**
- 该 HAP **格式完整、可用于提交**

### ⚠️ 尚未确定（需真机）

| 项 | 说明 |
|---|---|
| **能否侧载安装** | 网上资料矛盾：一方说"发布证书无法调试安装"，也有开发者反馈能装。**需真机实测 `hdc install`** |
| 运行时行为 | 界面、网络、小艺口令、华为账号登录、TokenCipher 冷启动 |

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

# 验证
& 'D:\DevEco\DevEco Studio\jbr\bin\java.exe' -jar `
  'D:\DevEco\DevEco Studio\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar' `
  verify-app -inFile '<signed.hap>' -outCertChain 'chain.cer' -outProfile 'profile.p7b'
```
