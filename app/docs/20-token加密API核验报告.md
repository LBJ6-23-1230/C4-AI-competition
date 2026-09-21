# AES-256-GCM + Asset Store Kit 用法确证报告

- **环境**：Windows / PowerShell
- **SDK**：`D:\DevEco\DevEco Studio\sdk`，compileSdkVersion = API 24（DevEco 6.1.1.125）
- **被确证的源码**：`liantiao4\app\entry\src\main\ets\api\TokenCipher.ets`
- **修正版**：（本报告的"可直接使用的 ArkTS 代码"一节）

> 证据分两类：**【SDK】**= 本机 d.ts 文件+行号（可复现）；**【文档】**= 华为/OpenHarmony 官方文档 URL。
> 本机 d.ts 的注释里**没有**列举 AES transformation 字符串，也没有 GCM authTag 的收发约定 ——
> 这两点必须靠官方文档，下面已给出原文。

---

## 一、可直接使用的 ArkTS 代码

完整修正版见 （本报告的"可直接使用的 ArkTS 代码"一节）。核心片段（同步 `encrypt` / `decrypt`）：

```ts
import { asset } from '@kit.AssetStoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

const TRANSFORMATION: string = 'AES256|GCM|NoPadding';
const KEY_ALG_NAME: string = 'AES256';
const NONCE_BYTES: number = 12;
const TAG_BYTES: number = 16;
const AAD: Uint8Array = new util.TextEncoder().encodeInto('zhixue-mate-token-v1');

/** 同步加密，返回 `nonce.密文.tag`（三段 Base64）；失败返回 null。 */
static encrypt(plain: string): string | null {
  const key = TokenCipher.key;                       // cryptoFramework.SymKey
  if (key === null || plain.length === 0) { return null; }
  try {
    const nonce: Uint8Array =
      cryptoFramework.createRandom().generateRandomSync(NONCE_BYTES).data;

    const spec: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: nonce },
      aad: { data: AAD },
      authTag: { data: new Uint8Array(TAG_BYTES) }   // 加密时是输出字段，占位即可
    };

    const cipher = cryptoFramework.createCipher(TRANSFORMATION);
    cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, spec);

    // doFinalSync 输出 = 密文 || 末尾16字节 authTag（官方约定，见问题4）
    const out: Uint8Array =
      cipher.doFinalSync({ data: util.TextEncoder.create().encodeInto(plain) }).data;
    const tagStart: number = out.length - TAG_BYTES;

    // 落盘格式：`nonce.密文.tag`，三段 Base64（b64 = new util.Base64Helper().encodeToStringSync）
    return `${b64(nonce)}.${b64(out.slice(0, tagStart))}.${b64(out.slice(tagStart))}`;
  } catch (e) { return null; }
}

/** 同步解密。tag 必须走 initSync 的 params，**不能**拼进 data。 */
static decrypt(encoded: string): string | null {
  const key = TokenCipher.key;
  if (key === null || encoded.length === 0) { return null; }
  const parts: string[] = encoded.split('.');
  if (parts.length !== 3) { return null; }
  try {
    const nonce: Uint8Array = fromB64(parts[0]);
    const cipherText: Uint8Array = fromB64(parts[1]);
    const authTag: Uint8Array = fromB64(parts[2]);
    if (authTag.length !== TAG_BYTES) { return null; }

    const spec: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: nonce },
      aad: { data: AAD },
      authTag: { data: authTag }                     // ← tag 在这里给
    };
    const cipher = cryptoFramework.createCipher(TRANSFORMATION);
    cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, key, spec);

    // ← 只喂纯密文！tag 校验失败时抛 17630001
    const plain: Uint8Array = cipher.doFinalSync({ data: cipherText }).data;
    return util.TextDecoder.create('utf-8', { ignoreBOM: true })
      .decodeToString(plain, { stream: false });
  } catch (e) { return null; }
}

/** 异步：密钥生成 / 资产库存取（幂等）。 */
static async initialize(): Promise<boolean> {
  const existing: Uint8Array | null = await TokenCipher.loadKeyBytes();
  if (existing !== null && existing.length > 0) {
    TokenCipher.key = await cryptoFramework
      .createSymKeyGenerator(KEY_ALG_NAME).convertKey({ data: existing });
  } else {
    const gen = cryptoFramework.createSymKeyGenerator(KEY_ALG_NAME);
    const generated: cryptoFramework.SymKey = await gen.generateSymKey();  // 256bit -> 32字节
    TokenCipher.key = generated;
    await TokenCipher.storeKeyBytes(generated.getEncoded().data);
  }
  return TokenCipher.key !== null;
}
```

`loadKeyBytes` / `storeKeyBytes`：

```ts
private static async loadKeyBytes(): Promise<Uint8Array | null> {
  try {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, stringToUint8(ALIAS));        // ALIAS 是 BYTES -> Uint8Array
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);  // 才会返回 SECRET
    const results: Array<asset.AssetMap> = await asset.query(query);
    if (results.length === 0) { return null; }
    const secret = results[0].get(asset.Tag.SECRET) as Uint8Array | undefined;
    return secret !== undefined && secret.length > 0 ? secret : null;
  } catch (e) {
    if ((e as BusinessErrorLike).code === 24000002) { return null; }  // NOT_FOUND
    throw e as Error;
  }
}

private static async storeKeyBytes(raw: Uint8Array): Promise<void> {
  const attributes: asset.AssetMap = new Map();
  attributes.set(asset.Tag.ALIAS, stringToUint8(ALIAS));
  attributes.set(asset.Tag.SECRET, raw);                          // 32 字节
  attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
  attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE); // 幂等
  await asset.add(attributes);
}
```

---

## 二、逐条回答 5 个问题

### 问题 1：AES-GCM 的 transformation 字符串

**结论：用 `'AES256|GCM|NoPadding'`。**（`'AES256|GCM|PKCS7'` 同样合法；`'AES256|GCM'` **不合法**；`'AES|GCM|NoPadding'` 自 API 10 起合法。）

**证据 1【SDK】** —— `@ohos.security.cryptoFramework.d.ts`：

- `createCipher` 声明在 **第 4281 行**：`function createCipher(transformation: string): Cipher;`
- 其 `@param transformation` 注释在 **第 4269–4270 行**，原文：

  ```
  @param { string } transformation - indicates the description to be transformed to cipher specifications.
                                    Multiple parameters need to be concatenated by "|".
  ```

  ❗注释里**没有**列举任何合法形式，也没有 AES 示例串。所以问题 1 **无法只靠本机 d.ts 回答**。

**证据 2【文档】** —— 对称密钥加解密算法规格（`crypto-sym-encrypt-decrypt-spec.md`，AES 节）：

> 当前支持以字符串参数完成AES加解密，具体的"字符串参数"由"对称密钥类型（加解密算法+密钥长度）"、"分组模式"和"填充模式"使用符号"|"拼接而成

| 分组模式 | 密钥长度（bit） | 填充模式 | API版本 |
| -------- | -------- | -------- | -------- |
| **GCM** | **[128\|192\|256]** | **[NoPadding\|PKCS5\|PKCS7]** | **9+** |

同文档举例："当需要分组模式为CFB、密钥长度为256bit、填充模式为NoPadding，其字符串参数为 `"AES256|CFB|NoPadding"`"。

**关键补充（同文档"填充模式"节原文）**：

> 对于CFB、OFB、CTR、GCM、CCM这类将分组密码转化为流模式实现的模式，不需要填充，因此**无论是否指定填充模式，都会按照NoPadding实现**。

→ 所以对 GCM 而言 `NoPadding` / `PKCS5` / `PKCS7` **完全等价**。官方 AES-GCM 指导示例用的是 `'AES128|GCM|PKCS7'`，你代码里的 `'AES256|GCM|NoPadding'` 也对。

**证据 3【文档】** —— 同文档"从API版本10开始，支持对称加解密不带密钥长度的规格"：

> 举例说明，当需要分组模式为CFB、不带密钥长度、填充模式为NoPadding，其字符串参数为 `"AES|CFB|NoPadding"`。

→ `'AES|GCM|NoPadding'` 合法（仍须**三段**）。

**判定表**：

| 候选 | 是否合法 | 依据 |
| --- | --- | --- |
| `'AES256\|GCM\|NoPadding'` | ✅ 推荐 | GCM 行 256 + NoPadding |
| `'AES256\|GCM\|PKCS7'` | ✅ 等价 | GCM 行 256 + PKCS7；且 GCM 按 NoPadding 实现 |
| `'AES\|GCM\|NoPadding'` | ✅（API 10+） | 不带密钥长度规格 |
| `'AES256\|GCM'` | ❌ | 文档中 AES 一律三段；无二段形式 |

URL：
- <https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/crypto-sym-encrypt-decrypt-spec-V5>
- 原文 md：<https://raw.giteeusercontent.com/openharmony/docs/raw/master/zh-cn/application-dev/security/CryptoArchitectureKit/crypto-sym-encrypt-decrypt-spec.md>

---

### 问题 2：`Cipher.initSync` 对称加密的签名

**结论：`initSync(opMode: CryptoMode, key: Key, params: ParamsSpec | null): void` —— 3 个参数，`params` 可为 `null`。**

**证据【SDK】** —— `@ohos.security.cryptoFramework.d.ts`：

- **`interface Cipher` 从第 3188 行开始**，`initSync` 在 **第 3551 行**，签名原文：

  ```ts
  initSync(opMode: CryptoMode, key: Key, params: ParamsSpec | null): void;
  ```

- 其注释（**第 3528–3550 行**）原文：

  ```
   * Init the crypto operation with the given crypto mode, key and parameters.
   * init, update, and doFinal must be used together. init and doFinal are mandatory, and update is optional.
   *
   * @param { CryptoMode } opMode - indicates the crypto mode is encryption or decryption.
   * @param { Key } key - indicates the symmetric key or the asymmetric key.
   * @param { ParamsSpec | null } params - indicates the algorithm parameters such as IV.
  ```

**要点（你之前抓错的原因）**：你抓到的是**别的 interface** 里的同名方法：

| 行号 | 所属 interface | 签名 | 说明 |
| --- | --- | --- | --- |
| **3551** | **`Cipher`** | `initSync(opMode: CryptoMode, key: Key, params: ParamsSpec \| null): void` | ✅ **对称+非对称通用，就是它** |
| 4411 | `Sign` | `initSync(priKey: PriKey): void` | 签名 |
| 4984 | `Verify` | `initSync(pubKey: PubKey): void` | 验签 |
| 2304 | `Mac` | `initSync(key: SymKey): void` | HMAC/CMAC |

`Cipher.initSync` **没有** `initSync(priKey, callback)` / `initSync(pubKey)` 这种重载 —— 那是 `Sign` 和 `Verify` 的。

**`params` 是否可 null**：类型是 `ParamsSpec | null`，**可以为 null**。但对于 GCM 必须传 `GcmParamsSpec`（iv/aad/authTag 都在里面），传 null 会失败。官方 API 参考原文：

> 适用于需要iv等参数的对称加解密模式（**对于无iv等参数的模式如ECB模式，无需构造，在init()中传入null即可**）

其他相关签名（同 interface，供对照）：

- 第 **3734** 行 `updateSync(data: DataBlob): DataBlob;`
- 第 **4061** 行 `doFinalSync(data: DataBlob | null): DataBlob;`（`data` **可传 null**）

---

### 问题 3：`SymKeyGenerator.convertKeySync` 与 `createSymKeyGenerator` 的 algName

**结论：`createSymKeyGenerator('AES256')` 是正确的；`convertKeySync({data: <32字节>})` 就是导入裸密钥的正确方式。algName 传 `'AES256'`，不要传 `'AES256|GCM'`。**

**证据 1【文档】** —— 对称密钥生成和转换规格（`crypto-sym-key-generation-conversion-spec.md`，AES 节）原文：

> 当前支持以字符串参数生成AES密钥，具体的"字符串参数"由"对称密钥算法"和"密钥长度"拼接而成，用于在创建对称密钥生成器时，指定密钥规格。

| 对称密钥算法 | 密钥长度（bit） | 字符串参数 | API版本 |
| -------- | -------- | -------- | -------- |
| AES | 128 | **AES128** | 9+ |
| AES | 192 | **AES192** | 9+ |
| AES | 256 | **AES256** | 9+ |

→ 只有"算法+长度"两段，**不含分组模式**。`'AES256|GCM'` 在密钥生成规格里不存在。

**证据 2【SDK】** —— `@ohos.security.cryptoFramework.d.ts`：

- 第 **2112** 行 `function createSymKeyGenerator(algName: string): SymKeyGenerator;`
  （注释第 2100–2111 行只说 `@param { string } algName - indicates the algorithm name. Multiple parameters need to be concatenated by "|".` —— 同样**不列举**具体串，必须靠上面的规格文档）

- 第 **2006** 行 `convertKeySync(key: DataBlob): SymKey;`
  注释（第 1993–2005 行）原文：
  ```
   * Used to convert symmetric key data to a symmetric key object.
   *
   * @param { DataBlob } key - the key data blob.
   * @returns { SymKey } return SymKey.
  ```
- 第 **1992** 行 `convertKey(key: DataBlob): Promise<SymKey>;`（异步版，你 `importKey` 用的就是它）
- 第 **1955** 行 `convertKey(key: DataBlob, callback: AsyncCallback<SymKey>): void;`（callback 版）

**两者关系**：`convertKeySync` 与 `convertKey` 是同一功能的同步/异步重载，都接收 `DataBlob`（即 `{ data: Uint8Array }`）。第 **188** 行 `interface DataBlob { data: Uint8Array; }`。

**长度约束**：`AES256` generator 的 `convertKey*` 要求正好 **32 字节**，否则抛 `401`。`generateSymKey()` 生成的就是 32 字节，所以 `generateSymKey().getEncoded()` 再 `convertKey` 能往返（第 **720** 行 `getEncoded(): DataBlob;`，第 **1907** 行 `generateSymKey(): Promise<SymKey>;`，第 **1918** 行 `generateSymKeySync(): SymKey;`）。

URL：<https://raw.giteeusercontent.com/openharmony/docs/raw/master/zh-cn/application-dev/security/CryptoArchitectureKit/crypto-sym-key-generation-conversion-spec.md>

---

### 问题 4：GCM 的 authTag 到底怎么放？ ⚠️ 你的理解对了一半

**逐项结论：**

| 你的陈述 | 判定 |
| --- | --- |
| ENCRYPT 模式下 `doFinalSync(data)` 返回的 DataBlob **末尾自带 16 字节 authTag** | ✅ **正确** |
| 必须先用 `setCipherSpec(CipherSpecItem.AEAD_TAG_LEN, ...)` 之类设置 | ❌ **不存在这个 API**，不需要也不能设 |
| 加密时 `authTag` 传 16 字节全零占位 | ✅ 可行（官方示例同款），但不是必须 |
| 解密时把**密文与 tag 拼接**后一起传 `doFinalSync` | ❌ **错误** —— 这是致命 bug |
| 解密时 `GcmParamsSpec.authTag` 填 tag | ✅ **正确，且是唯一正确途径** |

#### 4a. tag 从哪来？—— 来自 doFinal/doFinalSync 输出的**末尾 16 字节**

**证据【文档】** —— 官方 API 参考 `js-apis-cryptoFramework.md` 的 **GcmParamsSpec** 表 `authTag` 行原文：

> | authTag | DataBlob | 否 | 否 | 指明加解密参数authTag，长度为16字节。<br/>采用GCM模式加密时，需从[doFinal()]或[doFinalSync()]输出的DataBlob中**提取末尾16字节**，作为[init()]或[initSync()]方法中GcmParamsSpec的authTag。 |

同一句话在 4 个修订版里完全一致（OpenHarmony-4.0-Release / 4.1-Release / 5.0-Release / master），可交叉验证。

**证据【SDK】（较弱，仅方向性）** —— `@ohos.security.cryptoFramework.d.ts` 第 **379–403 行**，`GcmParamsSpec.authTag` 字段注释原文：

```
 * Indicates the output tag from the encryption operation. The tag is used for integrity check.
```

—— 明说 authTag 是**加密操作的 OUTPUT**（d.ts 没写"末尾16字节"，那部分只在 API 参考 md 里）。
同文件第 **544–547 行**（`Poly1305ParamsSpec.authTag`）给了最直白的收/发约定原文：

```
 * When encrypting, the data of authTag can be set to an empty Uint8Array;
 * When decrypting, the data of authTag must be set to the output tag from the encryption operation.
```

#### 4b. 要不要 `setCipherSpec(AEAD_TAG_LEN)`？—— **没有这个枚举项**

**证据【SDK】** —— `@ohos.security.cryptoFramework.d.ts` 第 **2902–3007 行** `enum CipherSpecItem`，**全部成员只有 5 个**：

| 名称 | 值 | 行号 |
| --- | --- | --- |
| `OAEP_MD_NAME_STR` | 100 | 2924 |
| `OAEP_MGF_NAME_STR` | 101 | 2946 |
| `OAEP_MGF1_MD_STR` | 102 | 2968 |
| `OAEP_MGF1_PSRC_UINT8ARR` | 103 | 2990 |
| `SM2_MD_NAME_STR` | 104 | 3006 |

**没有** `AEAD_TAG_LEN`，也没有任何 `GCM_*`。且 `setCipherSpec`（第 **4133** 行）注释（第 **4063–4064** 行）原文：

```
 * Set the specified parameter to the cipher object.
 * Currently, only the OAEP_MGF1_PSRC_UINT8ARR parameter in RSA is supported.
```

AES-GCM 的 tag **固定 16 字节**，没有可配置入口。官方文档原文亦确认：

> 在GCM模式下，算法库目前仅支持16字节的authTag，用于解密时的初始化认证。

#### 4c. 正确用法（官方 AES-GCM 指导的同步示例，逐字）

加密：

```ts
let cipher = cryptoFramework.createCipher('AES128|GCM|PKCS7');
cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, gcmParams);
let encryptUpdate = cipher.updateSync(plainText);
// gcm模式加密doFinal时传入空，获得tag数据，并更新至gcmParams对象中。
gcmParams.authTag = cipher.doFinalSync(null);
```

解密：

```ts
let decoder = cryptoFramework.createCipher('AES128|GCM|PKCS7');
decoder.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, gcmParams);
let decryptUpdate = decoder.updateSync(cipherText);
// gcm模式解密doFinal时传入空，验证init时传入的tag数据，如果验证失败会抛出异常。
let decryptData = decoder.doFinalSync(null);
```

原文档还带一条**专门澄清 doFinal 输出构成**的注释：

> 把update的结果拼接起来，得到密文（有些情况下还需拼接doFinal的结果，这取决于分组模式和填充模式，**本例中GCM模式的doFinal结果只包含authTag而不含密文**，所以不需要拼接）

→ 即：**doFinal 的输出 = 剩余密文 ‖ 16字节 tag**。
- 若数据全走 `update`，doFinal(null) 的结果就**只有** tag（16 字节）。
- 若一次把数据交给 `doFinal(data)`（不走 update），结果 = **密文 ‖ tag**，所以"提取末尾16字节"。

两种写法都对。**你的加密侧（`doFinalSync(明文)` 后 `slice(len-16)`）是正确的。**

#### 4d. ❌ 你的解密侧错在哪

你的 `TokenCipher.ets:173-174`：

```ts
const merged: Uint8Array = TokenCipher.concat(cipherText, authTag);   // ← 错
const decrypted: cryptoFramework.DataBlob = cipher.doFinalSync({ data: merged });
```

**为什么错**：GCM 的 tag 是对 **AAD ‖ ciphertext** 计算的。解密时算法库会用**你喂进去的全部字节**当作 ciphertext 去重算 tag。你在 `spec.authTag` 里已经给了正确 tag，但又多喂了 16 字节 —— 重算结果必然与 `spec.authTag` 不符，且这 16 字节还会被当作密文多"解"出一段垃圾。**结果是 `doFinalSync` 抛 `17630001`，`decrypt()` 永远返回 `null`**（即所有已登录用户每次启动都被判定为"无有效凭据"）。

官方 FAQ 明确把 `ciphertext` 和 `tag` 列为**两个独立输入**：

> doFinal失败，表示校验tag失败，解密输入的tag和解密过程中计算的tag不一致。解密输入的**key、iv、aad、tag和ciphertext**，任意一个不正确，都会导致该报错。
> 1. key不正确… 2. iv不正确… 3. aad不正确… 4. **ciphertext不正确**，update得到的明文不正确，doFinal失败 5. **tag不正确**，update得到的明文正确，doFinal失败

**修正**：只传纯密文，tag 只走 `GcmParamsSpec.authTag`（见 （本报告的"可直接使用的 ArkTS 代码"一节））。
另外 `GcmParamsSpec` 的 `algName` 必须设成 `'GcmParamsSpec'`（父类 `ParamsSpec.algName`，第 **240** 行；官方 API 参考："传入init()方法前需要指定其algName属性"）。你已设对。

**其他 GCM 参数约束【文档】**：
- `iv` 长度 **1~16 字节，常用 12 字节**（你用 12 ✅）
- `aad` 长度 0~INT_MAX，不用时可设 `{ data: new Uint8Array() }`

URL：
- <https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V14/crypto-aes-sym-encrypt-decrypt-gcm-V14>
- <https://raw.giteeusercontent.com/openharmony/docs/raw/master/zh-cn/application-dev/security/CryptoArchitectureKit/crypto-aes-sym-encrypt-decrypt-gcm.md>
- <https://raw.giteeusercontent.com/openharmony/docs/raw/master/zh-cn/application-dev/security/CryptoArchitectureKit/crypto-aes-sym-encrypt-decrypt-gcm-by-segment.md>
- <https://raw.giteeusercontent.com/openharmony/docs/raw/master/zh-cn/application-dev/security/CryptoArchitectureKit/crypto-aes-decryption-error-faq.md>
- <https://raw.giteeusercontent.com/openharmony/docs/raw/master/zh-cn/application-dev/reference/apis-crypto-architecture-kit/js-apis-cryptoFramework.md>

---

### 问题 5：Asset Store Kit 保存 32 字节密钥

**逐项结论：**

| 问题 | 结论 |
| --- | --- |
| `RETURN_TYPE` + `ReturnType.ALL` 是否足以拿到 `SECRET` | ✅ 是，且**必须**是 `ALL` |
| `Accessibility.DEVICE_FIRST_UNLOCKED` 是否合法、是否影响"启动即可读" | ✅ 合法，且它是**默认值**；正常应用启动读没问题 |
| alias 用 `Uint8Array` 还是 `string` | **必须 `Uint8Array`**（`ALIAS` 的 TagType 是 `BYTES`） |
| `remove`+`add` 幂等写法是否正确 | 能跑，但不是最好；**推荐 `CONFLICT_RESOLUTION = OVERWRITE`** |
| 重复 add 同 alias 抛什么错误码 | **`24000003`（The asset already exists）** |
| query 返回的 `AssetMap` 里 `SECRET` 的正确类型 | **`Uint8Array`** |

**证据【SDK】** —— `@ohos.security.asset.d.ts`：

- 第 **670** 行 `type AssetMap = Map<Tag, Value>;`
- 第 **1127** 行 `enum Tag`：
  - 第 **1141** 行 `SECRET = TagType.BYTES | 0x01,` —— 注释："A tag whose value is a byte array indicating the sensitive user data such as passwords and tokens." / "Asset plaintext."
  - 第 **1155** 行 `ALIAS = TagType.BYTES | 0x02,` —— 注释："Asset alias, which uniquely identifies an asset."（**BYTES → Uint8Array**）
  - 第 **1169** 行 `ACCESSIBILITY = TagType.NUMBER | 0x03,`
  - 第 **1450** 行 `RETURN_TYPE = TagType.NUMBER | 0x40,`
  - 第 **1513** 行 `CONFLICT_RESOLUTION = TagType.NUMBER | 0x44,`
- 第 **1068–1111** 行 `enum TagType`：`BOOL`(1082) / `NUMBER`(1096) / **`BYTES = 0x03 << 28`(1110)**
- 第 **702–751** 行 `enum Accessibility`：
  - 第 **716** 行 `DEVICE_POWERED_ON = 0`
  - 第 **733** 行 `DEVICE_FIRST_UNLOCKED = 1` —— 注释原文：
    ```
     * The asset can be accessed only after the device is unlocked for the first time.
     * <p><strong>NOTE</strong>:
     * If no lock screen password is set, this option is equivalent to <strong>DEVICE_POWERED_ON</strong>.
    ```
  - 第 **750** 行 `DEVICE_UNLOCKED = 2`
- 第 **958–993** 行 `enum ReturnType`：
  - 第 **975** 行 `ALL = 0` —— "The query result contains the asset plaintext and its attributes."
  - 第 **992** 行 `ATTRIBUTES = 1` —— "The query result contains only the asset attributes."
- 第 **913–942** 行 `enum ConflictResolution`：第 **927** 行 `OVERWRITE = 0` / 第 **941** 行 `THROW_ERROR = 1`
- 函数：第 **94** 行 `add` / **150** `addSync` / **195** `remove` / **238** `removeSync` / **291** `update` / **342** `updateSync` / **502** `query` / **556** `querySync`
- 错误码（在 `add` 注释里，第 **49–61** 行）：`24000001` 服务不可用、**`24000003` "The asset already exists."**、`24000005` 锁屏状态不匹配、`24000006` 内存不足、`24000007` 资产损坏、`24000008` 数据库失败、`24000009` 密码学操作失败…
  `query`/`remove` 注释里（第 **160/182/…** 行）：**`24000002` "The asset is not found."**

**证据【文档】** —— 官方《新增关键资产(ArkTS)》属性表原文（节选）：

| 属性名称（Tag） | 属性内容（Value） | 是否必选 | 说明 |
| --- | --- | --- | --- |
| SECRET | **类型为Uint8Array，长度为1-1024字节。** | **必选** | 关键资产明文。 |
| ALIAS | **类型为Uint8Array，长度为1-256字节。** | **必选** | 关键资产别名，每条关键资产的唯一索引。 |
| ACCESSIBILITY | 类型为number | 可选 | 基于锁屏状态的访问控制，**默认值为DEVICE_FIRST_UNLOCKED**，即首次解锁后可访问。 |
| CONFLICT_RESOLUTION | 类型为number | 可选 | 新增关键资产时的冲突（如：别名相同）处理策略，**默认值为THROW_ERROR**，即抛出异常，由业务进行后续处理。 |

官方《查询关键资产(ArkTS)》原文：

> 查询关键资产明文SECRET需要解密，查询时间较长，需要**将RETURN_TYPE设置为ALL**；只查询其他关键资产属性不需解密，查询时间较短，需要将RETURN_TYPE设置为ATTRIBUTES。

官方 `query` 示例逐字：

```ts
let query: asset.AssetMap = new Map();
query.set(asset.Tag.ALIAS, stringToArray('demo_alias'));
query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
asset.query(query).then((res: Array<asset.AssetMap>) => {
  for (let i = 0; i < res.length; i++) {
    let secret: Uint8Array = res[i].get(asset.Tag.SECRET) as Uint8Array;
    let secretStr: string = arrayToString(secret);
  }
});
```

→ `SECRET` 取出来就是 `Uint8Array`，**不用**再 `instanceof` 判断。

**"应用启动时即可读取"是否受影响？** 不受影响。
- `DEVICE_FIRST_UNLOCKED` 表示"设备首次解锁后可访问"。正常场景下应用 UI 只能在用户解锁后启动，所以启动时读一定成功。
- 唯一会失败的场景：开机后**尚未首次解锁**时由后台拉起（如开机自启的 ServiceExtension）。若确实要覆盖该场景，只能用 `DEVICE_POWERED_ON`（=0，安全性更低）。
- 未设锁屏密码时二者等价。

**关于"重复 add 同 alias"**：
- 默认（不设 `CONFLICT_RESOLUTION`）→ 抛 **`24000003`**（The asset already exists）。
- 你的 `remove` + `add`：能工作，但 **remove 对不存在的 alias 会抛 `24000002`**（你已吞掉），且两步之间不原子 —— 若在 remove 之后、add 之前进程被杀，密钥就永久丢了，此前加密的 token 全部无法解密。
- **推荐**：`attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);` 一步到位。
- 另外 asset 还提供 `updateSync(query, attributesToUpdate)`（第 **342** 行）可做真正的"只更新 SECRET"。

URL：
- <https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/asset-js-add>
- <https://raw.giteeusercontent.com/openharmony/docs/raw/master/zh-cn/application-dev/security/AssetStoreKit/asset-js-add.md>
- <https://raw.giteeusercontent.com/openharmony/docs/raw/master/zh-cn/application-dev/security/AssetStoreKit/asset-js-query.md>

---

## 三、你现有实现的错误清单

文件：`E:\C4-liantiao\liantiao4\app\entry\src\main\ets\api\TokenCipher.ets`

### 🔴 P0 — `decrypt()` 把 tag 拼进密文（第 173–174 行）

```ts
const merged: Uint8Array = TokenCipher.concat(cipherText, authTag);   // ❌
const decrypted: cryptoFramework.DataBlob = cipher.doFinalSync({ data: merged });
```

- **后果**：GCM tag 校验必然失败 → `doFinalSync` 抛 `17630001` → 被 catch 吞掉 → **`decrypt()` 永远返回 `null`**。用户每次冷启动都会被当成未登录。
- **修正**：删掉 `concat`，只传密文；tag 已在 `spec.authTag` 里（那部分你是对的）。
  ```ts
  const plain: Uint8Array = cipher.doFinalSync({ data: cipherText }).data;
  ```

### 🟠 P1 — `storeKeyBytes()` 的 remove+add 非原子（第 245–253 行）

- **后果**：两步之间崩溃 → 密钥永久丢失 → 已加密的 token 全部解不开（且没有回退路径）。`remove` 对不存在的 alias 抛 `24000002` 也被无条件吞掉，掩盖了真实错误（如 `24000004` access denied）。
- **修正**：改用 `CONFLICT_RESOLUTION = OVERWRITE` 单次 `add`，见修正版。

### 🟡 P2 — `decrypt()` 未校验 tag 长度（第 164 行）

`TokenCipher.fromBase64(parts[2])` 之后直接使用；若 Base64 解出非 16 字节，`initSync` 会抛 `401/17620003`。虽然被 catch 兜住返回 null（行为可接受），但显式校验更清晰、也避免误判为"密文被篡改"。

### 🟡 P3 — `encrypt()` 冗余拷贝（第 137 行）

```ts
new Uint8Array(new util.TextEncoder().encodeInto(plain))
```
`encodeInto(input?: string): Uint8Array`（`@ohos.util.d.ts:918`）本就返回 `Uint8Array`，外面再 `new Uint8Array(...)` 是多余的一次拷贝。直接 `util.TextEncoder.create().encodeInto(plain)` 即可。

### 🟡 P4 — `initialize()` 里 `generateSymKey()` 的裸密钥落库路径

第 101 行 `await TokenCipher.storeKeyBytes(generated.getEncoded());` —— **这个是对的**（`getEncoded(): DataBlob`，第 720 行）。仅提示：`storeKeyBytes` 参数名是 `raw: Uint8Array`，这里传的是 `DataBlob`。请确认 `storeKeyBytes` 内部取的是 `.data`（你的第 243 行 `attributes.set(asset.Tag.SECRET, raw)` 传的是形参，如果形参类型写成 `Uint8Array` 而实参传 `DataBlob`，ArkTS 编译期会报类型不匹配）。修正版已统一为传 `.data`。

### ✅ 以下部分确认正确，无需改动

| 位置 | 内容 | 依据 |
| --- | --- | --- |
| 第 126 / 165 行 | `'AES256\|GCM\|NoPadding'` | 问题 1 |
| 第 135 / 172 行 | `initSync(mode, key, spec)` 三参数 | 问题 2（d.ts:3551） |
| 第 98 / 212 行 | `createSymKeyGenerator('AES256')` | 问题 3 |
| 第 213 行 | `generator.convertKey({ data: raw })` 导入裸密钥 | 问题 3（d.ts:1992） |
| 第 137–142 行 | 加密后取**末尾 16 字节**为 tag | 问题 4a |
| 第 133 行 | 加密时 authTag 填 16 字节 0 占位 | 问题 4（可行） |
| 第 129–134 / 166–171 行 | `algName: 'GcmParamsSpec'`、iv 12 字节、固定 AAD | 问题 4d |
| 第 220–221 行 | ALIAS 用 `stringToUint8`、`RETURN_TYPE = ALL` | 问题 5 |
| 第 226–227 行 | `results[0].get(asset.Tag.SECRET) as Uint8Array` | 问题 5 |
| 第 232 行 | `24000002` 视为首次运行 | 问题 5 |
| 第 244 行 | `DEVICE_FIRST_UNLOCKED` | 问题 5 |
| 第 188–190 行 | `generateRandomSync(12)` 生成 nonce | d.ts:1332 |

---

## 四、置信度

### 硬证据（本机 SDK d.ts 行号，可直接复现）

| 结论 | 出处 |
| --- | --- |
| `initSync(opMode, key, params)` 三参数、`params` 可 null | cryptoFramework.d.ts **3551** |
| `Cipher` 里没有非对称版 `initSync`（那是 Sign/Verify） | **4411 / 4984** |
| `doFinalSync(data: DataBlob \| null)` | **4061** |
| `updateSync(data): DataBlob` | **3734** |
| `CipherSpecItem` 只有 5 项，**无 `AEAD_TAG_LEN`/`GCM_*`** | **2902–3007** |
| `setCipherSpec` 注释："only the OAEP_MGF1_PSRC_UINT8ARR parameter in RSA" | **4063–4064** |
| `GcmParamsSpec.authTag` 注释："the **output** tag from the encryption operation" | **380–403** |
| Poly1305 注释：加密可空、解密必须是加密输出 | **544–547** |
| `convertKeySync(key: DataBlob): SymKey` / `convertKey(key: DataBlob): Promise<SymKey>` | **2006 / 1992** |
| `createSymKeyGenerator` / `getEncoded` / `generateRandomSync` | **2112 / 720 / 1332** |
| `DataBlob.data: Uint8Array` / `ParamsSpec.algName: string` | **188 / 240** |
| asset：`SECRET`/`ALIAS` 是 `TagType.BYTES` | **1141 / 1155** |
| asset：`Accessibility.DEVICE_FIRST_UNLOCKED = 1` | **733** |
| asset：`ReturnType.ALL = 0` / `ATTRIBUTES = 1` | **975 / 992** |
| asset：`ConflictResolution.OVERWRITE = 0` / `THROW_ERROR = 1` | **927 / 941** |
| asset：重复 add 抛 **`24000003`**；query/remove 找不到抛 **`24000002`** | **50 / 160 / 182** |
| util：`Base64Helper.encodeToStringSync` / `decodeSync` | util.d.ts **3291 / 3348** |

### 官方文档硬证据

| 结论 | 出处 |
| --- | --- |
| AES-GCM 字符串 = `算法+长度 \| GCM \| [NoPadding\|PKCS5\|PKCS7]`，GCM 一律按 NoPadding 实现 | crypto-sym-encrypt-decrypt-spec.md |
| AES256 生成器 algName = `'AES256'` | crypto-sym-key-generation-conversion-spec.md |
| **tag = doFinal/doFinalSync 输出的末尾 16 字节** | js-apis-cryptoFramework.md（GcmParamsSpec 行，4 个修订版一致） |
| GCM 只支持 16 字节 authTag | crypto-aes-sym-encrypt-decrypt-gcm.md |
| **doFinal 输出 = 剩余密文 ‖ tag**（"GCM模式的doFinal结果只包含authTag而不含密文"指全走 update 的情形） | crypto-aes-sym-encrypt-decrypt-gcm-by-segment.md |
| 解密时 key/iv/aad/**tag**/ciphertext 是**5 个独立输入** | crypto-aes-decryption-error-faq.md |
| ALIAS/SECRET 为 Uint8Array；ACCESSIBILITY 默认 DEVICE_FIRST_UNLOCKED；CONFLICT_RESOLUTION 默认 THROW_ERROR；RETURN_TYPE=ALL 才返回明文 | asset-js-add.md / asset-js-query.md |

### 推断（有依据但非逐字明说）

1. **"解密时把 tag 拼进密文会导致 `decrypt()` 永远返回 null"** —— 文档**没有**一句"不要拼接 tag"的明文禁令。此结论由三条硬证据合成：
   (a) API 参考说 tag 要放进 `init` 的 `GcmParamsSpec`；(b) FAQ 把 tag 与 ciphertext 列为独立输入；(c) 所有官方示例的解密侧都只传纯密文。
   叠加 GCM/OpenSSL 语义（tag 是对 ciphertext 计算的），多喂 16 字节必然校验失败。**判定为错误是安全的**，但严格说这一步是推断而非逐字引证。
2. `'AES256|GCM'`（二段）非法 —— 文档只给了三段形式，二段**未出现**；推断为非法（而非实测报错码）。实际会抛 `401` 或 `801`（`createCipher` 的 `@throws`，d.ts 4272–4275）。
3. `createCipher` 的本机 d.ts 注释**没有**列举合法 transformation（已逐行确认 4264–4281）—— 因此问题 1 只能靠官方文档。

### 未能确证

- **未能确证** "`doFinalSync(明文)` 一次调用（不走 update）在 *所有* 情况下都返回 `密文‖tag`" —— 官方示例只演示了 `update + doFinal(null)`；"末尾 16 字节是 tag" 的表述来自 API 参考表格，属于文档约定，我**没有在本机运行验证**（本会话无 HarmonyOS 设备/模拟器，且沙箱禁止 pwsh 直连网络下载校验）。
  你的加密侧写法与"取末尾 16 字节"的文档约定一致，**风险低**；若想 100% 对齐官方示例，可改成 `updateSync(明文)` + `doFinalSync(null)`（此时 doFinal 结果**恰好**是 16 字节 tag，无需切片猜测）。
- **未能确证** OpenHarmony `CryptoArchitectureKit` 的 C++ 实现细节（`cipher_openssl.cpp` 中 `EVP_EncryptFinal_ex` / `EVP_CIPHER_CTX_ctrl` 的具体调用次序）—— 本会话无法访问该源码仓库（pwsh 直连网络被沙箱阻断，`web_fetch` 对大文件会截断到 ~106KB，`Cipher` 章节位于文档更后段）。
- **未能确证** `asset.query` 在资产存在但**当前锁屏状态不允许访问**时的具体返回（是抛 `24000005` 还是空数组）—— 文档列出 `24000005 The screen lock status does not match`，但未说明 `query` 是否抛该码。

---

## 五、复现用命令

```powershell
# 确认 SDK 文件
Get-Item "D:\DevEco\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.security.cryptoFramework.d.ts",
        "D:\DevEco\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.security.asset.d.ts" |
  Select-Object FullName,Length,LastWriteTime

# 关键行号定位（grep 工具）
#   cryptoFramework.d.ts : initSync=3551  doFinalSync=4061  updateSync=3734
#                          setCipherSpec=4133  CipherSpecItem=2902-3007
#                          GcmParamsSpec=328-404  convertKeySync=2006  createSymKeyGenerator=2112
#   asset.d.ts           : Tag=1127  Accessibility=702  ReturnType=958  ConflictResolution=913
```

> 注：本会话 pwsh 被沙箱限制，`Invoke-WebRequest` / `curl.exe` 直连外网均失败
> （`schannel: SEC_E_NO_CREDENTIALS`），所有在线文档均通过 `web_fetch` 获取。
