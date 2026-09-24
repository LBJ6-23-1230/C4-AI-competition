# 发布证书 + 发布 Profile 操作手册（无手机路线）

> 目的：**不借手机**，在 AGC 上拿到「发布证书 + 发布 Profile」，从而在 DevEco 里手动签名产出 `entry-default-signed.hap`，用于比赛提交 zip。
> 适用账号：队长 `hid54418790`（已认证）
> 前置状态：AGC 应用 `知学Mate`（`com.zhixue.mate`）已创建 ✅ · 调试证书已申请 ✅

---

## 零、先分清两个"证书"别搞混

AGC 里「证书」页可以同时存在**多张证书**，这是两套独立的东西：

| | 调试证书 | 发布证书 |
|---|---|---|
| 用途 | 真机调试 | 打包发布 / 上架 |
| 是否已申请 | ✅ 已有 | ❌ 本次要申请 |
| 配套 Profile 类型 | 调试（**绑定设备**） | 发布（**不绑定设备**） |
| 能否侧载安装 | ✅ 能 | ⚠️ 多数资料说**不能**，见 §六 |
| 有效期 | 1 年，不可续期 | 见证书详情 |

> **关键点：这次只申请"发布证书"，不要去动已有的调试证书。**

---

## 一、申请发布证书（3 分钟）

### 步骤

1. 打开 AGC：[AppGallery Connect](https://developer.huawei.com/consumer/cn/service/josp/agc/index.html#/)
2. 左上角选中项目 → 左侧导航 **「证书、APP ID 和 Profile」**
3. 左侧子菜单 → **「证书」** 页签
4. 右上角点 **「新增证书」**
5. 弹窗里填：

| 字段 | 填什么 |
|---|---|
| 证书名称 | `zhixue-release`（任意，建议区分开） |
| **证书类型** | ⚠️ 选 **「发布证书」**（千万别选成调试） |
| 证书请求文件 | 上传 `E:\zhixue-signing\zhixue.csr` |

6. 提交 → 列表里出现新证书 → 点 **「下载」**
7. 保存到本地，建议：

```
E:\zhixue-signing\zhixue-release-cert.cer
```

### 关于 `.csr` 能不能复用（重要）

**能，直接用现成的 `zhixue.csr`。** 证书是围绕密钥对签发的，CSR 只是"公钥 + 主体信息"的申请单，同一个密钥对可以签发多张证书。

**不要**再去 DevEco 点「Generate Key and CSR」——那会生成新的 `.p12`/`.csr`，把现有材料搞乱。

> 下载下来的 `.cer` 和调试那个一样，是 **PEM 文本**（3 段证书链）。DevEco 接受 `.cer`。

---

## 二、"访问发布类Profile"权限到底要不要申请

**我的结论：多半不需要，先跳过，卡住了再处理。**

### 理由

网上的官方文档（旧版）把"已获取『访问发布类Profile』权限"列为前提条件，但**这个权限对大多数账号是默认开通的，页面上没有申请入口**。你已有的调试证书和调试 Profile 都申请成功了，说明账号的基础权限是正常的。

### 如果第二步真的卡住了

在 AGC 里按这个顺序找（不同版本入口位置不同）：

1. **「证书、APP ID 和 Profile」→「Profile」→ 右上角「添加」**
   - 如果"类型"下拉里 **「发布」是灰色不可选** → 才是权限问题
2. 找入口的位置（按可能性排序）：
   - 账号头像 → **「我的账号」/「账号中心」→ 权限管理**
   - **「用户与访问」→「用户」→ 你的账号 →「角色/权限」**
   - 直接提工单：AGC 右下角 **「在线客服」**，或发邮件给华为开发者支持
3. 提工单话术（直接抄）：

> 您好，我是个人开发者（账号 hid54418790），已创建 HarmonyOS 应用并申请了调试证书与调试 Profile。现需申请**发布证书**与**发布 Profile** 用于提交比赛作品（非上架）。在 Profile 页面新增时无法选择"发布"类型，请问「访问发布类Profile」权限如何开通？谢谢。

---

## 三、申请发布 Profile（与调试 Profile 的唯一区别：无设备）

1. 左侧 → **「Profile」** 页签 → 右上角 **「添加」**
2. 填写：

| 字段 | 填什么 |
|---|---|
| 应用名称 | 选 `知学Mate` |
| 包名 | 自动填充 `com.zhixue.mate` |
| Profile 名称 | `zhixue-release-profile` |
| **类型** | 选 **「发布」** |
| 选择证书 | 选第一步的 **`zhixue-release`**（发布证书） |

3. **设备那一步：发布类型不需要绑定任何设备** —— 这是与调试 Profile 的关键差异，也是"无手机"路线的立足点
4. ACL 权限：**不需要**，跳过
5. 提交 → 下载：

```
E:\zhixue-signing\zhixue-release.p7b
```

6. **顺便确认一个好消息**：发布 Profile 申请成功后，**其关联发布证书的指纹会自动加到应用上**，不需要像调试证书那样手动配指纹。

---

## 四、在 DevEco 里配置手动签名

**⚠️ 一定不要勾「Automatically generate signature」** —— 自动签名会重新生成一套签名材料，把 `appid` 随机化，会打断小艺/华为账号的授权关系。

1. DevEco 打开 `E:\C4-liantiao\liantiao5\app`
2. 菜单 **File → Project Structure → Signing Configs**
3. **取消勾选** `Automatically generate signature`
4. 点 `+` 新建一个配置，命名 `release`，三个文件分别选：

| 字段 | 文件 |
|---|---|
| Store file (.p12) | `E:\zhixue-signing\zhixue-debug.p12` |
| Store password | 你创建 p12 时设的密码 |
| Key alias | 创建时的别名 |
| Key password | 同上 |
| Profile file (.p7b) | `E:\zhixue-signing\zhixue-release.p7b` |
| Certpath file (.cer) | `E:\zhixue-signing\zhixue-release-cert.cer` |

5. OK 保存 → DevEco 会把配置写进 `app/build-profile.json5` 的 `signingConfigs` 数组
6. 确认 `products[0].signingConfig` 指向 `"release"`（原来是悬空的 `"default"`）
7. **Build → Build Hap(s)/APP(s) → Build Hap(s)**
8. 产物路径：

```
liantiao5/app/entry/build/default/outputs/default/entry-default-signed.hap
```

### 签名成功的判据（别被"假成功"骗了）

看 `build.log`：

- ✅ `SignHap` 任务耗时 **几百 ms ~ 数秒**
- ❌ 耗时 **1ms** = 签名被跳过（上一轮就是这个情况，产物还是 `-unsigned`）
- ✅ 产物文件名**不含** `-unsigned`

---

## 五、验证证书与 Profile 对得上

签名前可以先用 keytool 自查（避免"文件选错"这种低级坑）：

```powershell
# 看发布证书主题与有效期
keytool -printcert -file E:\zhixue-signing\zhixue-release-cert.cer

# 看 p12 里的别名（要和 DevEco 里 Key alias 一致）
keytool -list -keystore E:\zhixue-signing\zhixue-debug.p12 -storetype PKCS12
```

**校验要点**：发布证书的 **公钥** 必须与 `.p12` 里的私钥配对。因为复用了同一个 `.csr`，所以必然配对 ✅。

> 参考：你已有的调试证书 leaf SHA256 = `DF:21:A3:C0:9F:79:54:57:93:05:F8:5C:64:F8:0C:AD:86:F7:98:53:EE:3A:88:7C:1D:EC:95:D2:18:DF:3A:37`。
> 复用了同一密钥对，所以**发布证书的指纹很可能与它相同或高度相关**——这是正常的，不用慌。

---

## 六、⚠️ 必须实测的一件事：发布签名包到底能不能装

网上资料在这里**互相矛盾**：

| 说法 | 来源 |
|---|---|
| "发布证书无法调试安装" | 华为开发者问答标题；华为云社区教程原文"发布签名是不能运行的，只能发布上架" |
| "发布签名不能侧载装到手机" | 与上一条一致 |
| 有开发者反馈发布签名 HAP 能直接安装 | 部分社区帖 |

**我不替你下结论，给你一个 10 分钟就能验证的判定**：

1. 先按本手册产出发布签名的 HAP
2. 借到手机的当天，用 `hdc install entry-default-signed.hap` 试一次
3. 结果分流：
   - **装上了** → 太好了，路线 B 完全等价于路线 A，手机只需最后录视频时借
   - **装不上**（报签名/证书不匹配） → 说明确实只能走调试 Profile；此时**不影响比赛提交**，因为附加分要求的是"可演示的 HAP 文件"，zip 里有签名包即可，视频用模拟器/录屏录

> 无论哪种结果，**这次申请都不白做**：发布证书是上架的必要条件，而上架在评分表里是明确的加分项。

---

## 七、执行清单

```
□ AGC「证书」页 → 新增证书 → 类型选「发布」→ 上传 zhixue.csr
□ 下载 zhixue-release-cert.cer 到 E:\zhixue-signing\
□ AGC「Profile」页 → 添加 → 类型选「发布」→ 选发布证书 → 不绑设备
□ 下载 zhixue-release.p7b 到 E:\zhixue-signing\
□ DevEco File → Project Structure → Signing Configs
   □ 取消勾选 Automatically generate signature
   □ 新建 release 配置，填 .p12 + .p7b + .cer
□ 确认 products[0].signingConfig = "release"
□ Build Hap(s)
□ 检查 build.log 的 SignHap 耗时 ≠ 1ms
□ 确认产物为 entry-default-signed.hap（无 -unsigned）
□ 借到手机后实测 hdc install，记录结果
```

---

## 八、卡住时的排查

| 现象 | 原因 | 处理 |
|---|---|---|
| Profile"类型"里「发布」灰色 | 权限未开通 | 见 §二 提工单 |
| 新增证书报"CSR 格式不正确" | 上传了 `.p12` 而非 `.csr` | 确认文件是 `zhixue.csr` |
| 签名报 "profile 与证书不匹配" | Profile 选的证书 ≠ 上面填的 .cer | 两者必须是同一张发布证书 |
| 签名报 "keystore password 错误" | p12 密码/别名不对 | `keytool -list` 核对 |
| `SignHap` 耗时 1ms | 签名被跳过 | 检查 `signingConfigs` 是否真空了 |
| 装机报 "device not in profile" | 用的是调试 Profile，设备未注册 | 换发布 Profile，或去 AGC 注册该 UDID |
