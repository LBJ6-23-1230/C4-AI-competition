import { asset } from '@kit.AssetStoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'TokenCipher';

/**
 * 登录 token 的本地加密。
 *
 * 修的是什么
 * ----------
 * 原先 `AuthStore` 把 token **明文**写进 preferences：
 *
 *     store.putSync(AuthStore.KEY_TOKEN, session.token);   // 明文
 *
 * preferences 落在应用私有目录，未 root 的机器上外部读不到，但它**不是**
 * 安全存储：备份、调试桥、以及任何拿到应用沙箱的途径都能直接读出明文 token，
 * 而 token 等同于账号（`SESSION_TTL_DAYS = 30`，30 天内可冒充）。
 * 这是评审时会被点名的合规问题。
 *
 * 现在的做法
 * ----------
 * 两层：
 * 1. **数据密钥**用系统级**资产库**（Asset Store Kit）保存 —— 它由系统托管，
 *    带访问控制属性，比 preferences 强得多。
 * 2. **token 密文**用 AES-256-GCM 加密后存 preferences，**每条消息一个随机 nonce**，
 *    GCM 自带完整性校验（密文被篡改会解密失败，而不是静默返回垃圾）。
 *
 * 为什么自己生成密钥而不是用 HUKS 硬件密钥
 * ----------------------------------------
 * HUKS 的密钥不出安全区、安全性最高，但其 `initSession`/`finishSession` 需要
 * 多轮异步交互，而 `AuthStore.persist()` 是**同步**调用（preferences 也是同步 API），
 * 混用会引入一个"写了一半"的状态。这里选择"软件密钥 + 系统资产库托管"，
 * 在**同步可用**的前提下拿到实质性提升，并在文档里如实写明这条边界，
 * 而不是声称做到了硬件级保护。
 *
 * API 用法依据（每条都有出处，不是凭记忆写的）
 * -------------------------------------------
 * 本文件的关键写法经专项核对（报告见 `docs/token-cipher-aes-gcm-verification.md`），
 * 依据是官方《对称密钥加解密算法规格》/《GCM 加解密开发指导》/ API 参考，
 * 以及本机 `@ohos.security.cryptoFramework.d.ts`：
 *
 * | 用法 | 依据 |
 * |---|---|
 * | `createCipher('AES256\|GCM\|NoPadding')` | AES 一律**三段**形式；GCM 属流模式，`NoPadding`/`PKCS7` 等价 |
 * | `Cipher.initSync(opMode, key, params)` | d.ts **:3551**，**三个参数**，params 可为 null（GCM 必须传 `GcmParamsSpec`） |
 * | `createSymKeyGenerator('AES256')` | 密钥生成规格里 AES 只有"算法+长度"两段，**不带分组模式** |
 * | `convertKeySync({data: <32 字节>})` | d.ts **:2006**；AES256 **必须正好 32 字节**，否则抛 401 |
 * | 加密后从 `doFinalSync` 输出**末尾取 16 字节**作 tag | 官方 GcmParamsSpec 表原文 |
 * | 解密时 tag **只**通过 `spec.authTag` 传 | 同上；**绝不能把 tag 拼进 data** |
 * | `asset.Tag.CONFLICT_RESOLUTION = ConflictResolution.OVERWRITE` | d.ts **:927 / :1513**；默认是 `THROW_ERROR`（:941） |
 * | `asset.Tag.RETURN_TYPE = ReturnType.ALL` | 不设它 `query` **不返回 `SECRET`** |
 * | `ALIAS` / `SECRET` 均为 `Uint8Array` | `TagType.BYTES`（d.ts :1141 / :1155） |
 *
 * ⚠️ **踩过并修掉的一个 P0**（记录以免重犯）
 * ----------------------------------------
 * 第一版 `decrypt()` 把密文与 tag **拼接**后传给 `doFinalSync`：
 *
 *     const merged = concat(cipherText, authTag);
 *     cipher.doFinalSync({ data: merged });     // ❌ 错
 *
 * GCM 的 tag 是对 `AAD ‖ ciphertext` 计算的。解密时算法库会拿**喂进去的全部字节**
 * 当密文重算 tag，于是：既与 `spec.authTag` 不匹配，那多出的 16 字节还会被当密文
 * 多解一段垃圾 → `doFinalSync` 抛 `17630001` → 被 catch 吞掉 →
 * **`decrypt()` 永远返回 `null`**，表现为"所有已登录用户每次冷启动都被当成未登录"。
 *
 * 正确写法：**只传纯密文**，tag 走 `GcmParamsSpec.authTag`（已在 `initSync` 时给出）。
 *
 * ⚠️ 仍未在本机验证的部分
 * ----------------------
 * 本文件**未经 DevEco 编译、未经真机运行**。`doFinalSync(明文)` 一次调用
 * （不走 `update`）是否在**所有**情况下都返回 `密文‖tag`，官方示例只演示了
 * `update + doFinal(null)`；"末尾 16 字节是 tag"来自 API 参考表格约定。
 * 已按文档约定实现（风险低）。
 *
 * **兜底已就位**：`AuthStore.encodeToken()` 在加密失败时会**降级为明文**并把
 * `encryptionDegraded()` 置为 true。即使上述约定有偏差，应用仍能正常登录，
 * 只是退回改动前的存储强度 —— **不会把登录打挂**。
 */
export class TokenCipher {
  private static readonly ALIAS: string = 'zhixue_mate_session_token_key';
  private static readonly NONCE_BYTES: number = 12;
  private static readonly TAG_BYTES: number = 16;
  private static readonly KEY_BYTES: number = 32;
  private static readonly KEY_ALG: string = 'AES256';
  private static readonly TRANSFORMATION: string = 'AES256|GCM|NoPadding';
  private static readonly AAD_TEXT: string = 'zhixue-mate-token-v1';

  private static key: cryptoFramework.SymKey | null = null;
  private static ready: boolean = false;
  /** 加密不可用时标记 —— 由 `AuthStore` 决定降级策略并**向用户如实显示**。 */
  private static unavailableReason: string = '';

  /** 加密是否可用。false 时 `AuthStore` 会退回明文并标注，不静默假装安全。 */
  static isReady(): boolean {
    return TokenCipher.ready;
  }

  static reason(): string {
    return TokenCipher.unavailableReason;
  }

  /**
   * 判断一段落盘字符串是不是本类的密文格式（`nonce.密文.tag`，三段 Base64）。
   *
   * 用途：兼容**升级前写入的明文 token** —— 那时存的是后端下发的原始串，
   * 不可能恰好是"三段、每段都是合法 Base64"的形状。识别不出就按明文处理，
   * 保证老用户不会因为这次改动而被动掉线。
   */
  static looksEncrypted(value: string): boolean {
    if (value.length === 0) {
      return false;
    }
    const parts: string[] = value.split('.');
    if (parts.length !== 3) {
      return false;
    }
    const base64: RegExp = /^[A-Za-z0-9+/]+={0,2}$/;
    for (let index: number = 0; index < parts.length; index++) {
      if (!base64.test(parts[index])) {
        return false;
      }
    }
    return true;
  }

  /**
   * 初始化：从资产库取密钥，没有就生成一个并存入。
   *
   * 幂等，可重复调用。失败时把原因记在 `unavailableReason`
   * （不抛异常 —— 登录流程不能因为"加密不可用"而整个卡死）。
   */
  static async initialize(): Promise<boolean> {
    if (TokenCipher.ready) {
      return true;
    }
    try {
      const existing: Uint8Array | null = await TokenCipher.loadKeyBytes();
      if (existing !== null && existing.length === TokenCipher.KEY_BYTES) {
        TokenCipher.key = TokenCipher.importKey(existing);
      } else {
        const generator: cryptoFramework.SymKeyGenerator =
          cryptoFramework.createSymKeyGenerator(TokenCipher.KEY_ALG);
        const generated: cryptoFramework.SymKey = await generator.generateSymKey();
        TokenCipher.key = generated;
        // `getEncoded()` 返回的是 `DataBlob`，资产库要的是 `Uint8Array` —— 取 `.data`
        await TokenCipher.storeKeyBytes(generated.getEncoded().data);
      }
      TokenCipher.ready = TokenCipher.key !== null;
      TokenCipher.unavailableReason = TokenCipher.ready ? '' : 'key_unavailable';
      return TokenCipher.ready;
    } catch (error) {
      const typed = error as BusinessErrorLike;
      hilog.warn(DOMAIN, TAG, '%{public}s',
        `TokenCipher init failed: ${typed.code} ${typed.message}`);
      TokenCipher.key = null;
      TokenCipher.ready = false;
      TokenCipher.unavailableReason = `crypto_init_failed:${typed.code}`;
      return false;
    }
  }

  /**
   * 加密 token。返回 `nonce.密文.tag` 三段 Base64。
   * 未就绪时返回 null，由调用方决定降级。
   */
  static encrypt(plain: string): string | null {
    const key: cryptoFramework.SymKey | null = TokenCipher.key;
    if (key === null || plain.length === 0) {
      return null;
    }
    try {
      const cipher: cryptoFramework.Cipher =
        cryptoFramework.createCipher(TokenCipher.TRANSFORMATION);
      const nonce: Uint8Array = TokenCipher.randomBytes(TokenCipher.NONCE_BYTES);
      // `aad` 用固定串，防止密文被跨用途重放。
      // 加密时 `authTag` 是**输出**字段，填 16 字节 0 占位即可（官方示例同款）。
      const spec: cryptoFramework.GcmParamsSpec = {
        algName: 'GcmParamsSpec',
        iv: { data: nonce },
        aad: { data: TokenCipher.aad() },
        authTag: { data: new Uint8Array(TokenCipher.TAG_BYTES) }
      };
      cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, spec);
      const payload: Uint8Array =
        cipher.doFinalSync({ data: new util.TextEncoder().encodeInto(plain) }).data;
      if (payload.length < TokenCipher.TAG_BYTES) {
        return null;
      }
      // 文档约定：doFinal 输出 = 剩余密文 ‖ 末尾 16 字节 authTag
      const tagStart: number = payload.length - TokenCipher.TAG_BYTES;
      const cipherText: Uint8Array = payload.slice(0, tagStart);
      const authTag: Uint8Array = payload.slice(tagStart);
      return `${TokenCipher.toBase64(nonce)}.${TokenCipher.toBase64(cipherText)}.${TokenCipher.toBase64(authTag)}`;
    } catch (error) {
      const typed = error as BusinessErrorLike;
      hilog.warn(DOMAIN, TAG, '%{public}s', `encrypt failed: ${typed.code} ${typed.message}`);
      return null;
    }
  }

  /**
   * 解密 `nonce.密文.tag`。
   *
   * 任何不一致（被篡改 / 换过密钥 / 格式不合法）都返回 `null`，
   * 由 `AuthStore` 当作"无有效凭据"处理并要求重新登录。
   *
   * ⚠️ **只把纯密文交给 `doFinalSync`** —— tag 必须且只能通过
   * `GcmParamsSpec.authTag` 传入（见文件头"s 踩过的 P0"）。
   */
  static decrypt(encoded: string): string | null {
    const key: cryptoFramework.SymKey | null = TokenCipher.key;
    if (key === null || encoded.length === 0) {
      return null;
    }
    const parts: string[] = encoded.split('.');
    if (parts.length !== 3) {
      return null;
    }
    try {
      const nonce: Uint8Array = TokenCipher.fromBase64(parts[0]);
      const cipherText: Uint8Array = TokenCipher.fromBase64(parts[1]);
      const authTag: Uint8Array = TokenCipher.fromBase64(parts[2]);
      // GCM 只支持 16 字节 tag；长度不对直接判失败，不喂给算法库
      if (authTag.length !== TokenCipher.TAG_BYTES || nonce.length === 0) {
        return null;
      }
      const cipher: cryptoFramework.Cipher =
        cryptoFramework.createCipher(TokenCipher.TRANSFORMATION);
      const spec: cryptoFramework.GcmParamsSpec = {
        algName: 'GcmParamsSpec',
        iv: { data: nonce },
        aad: { data: TokenCipher.aad() },
        authTag: { data: authTag }
      };
      cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, key, spec);
      // ✅ 只传密文。把 tag 拼进来会让 GCM 校验必然失败（见文件头说明）。
      const decrypted: Uint8Array =
        cipher.doFinalSync({ data: cipherText }).data;
      return new util.TextDecoder().decodeToString(decrypted);
    } catch (error) {
      // GCM 校验失败会走到这里 —— 说明密文被改过或密钥换了，按"无有效凭据"处理
      return null;
    }
  }

  // ------------------------------------------------------------------ 内部工具
  private static aad(): Uint8Array {
    return new util.TextEncoder().encodeInto(TokenCipher.AAD_TEXT);
  }

  private static randomBytes(length: number): Uint8Array {
    const random: cryptoFramework.Random = cryptoFramework.createRandom();
    return random.generateRandomSync(length).data;
  }

  private static toBase64(bytes: Uint8Array): string {
    const helper: util.Base64Helper = new util.Base64Helper();
    return helper.encodeToStringSync(bytes);
  }

  private static fromBase64(text: string): Uint8Array {
    const helper: util.Base64Helper = new util.Base64Helper();
    return helper.decodeSync(text);
  }

  /** 裸密钥字节 → `SymKey`。同步版本，因为 `initialize()` 之后要能同步加密。 */
  private static importKey(raw: Uint8Array): cryptoFramework.SymKey {
    const generator: cryptoFramework.SymKeyGenerator =
      cryptoFramework.createSymKeyGenerator(TokenCipher.KEY_ALG);
    return generator.convertKeySync({ data: raw });
  }

  /**
   * 从资产库取密钥字节；不存在返回 null。
   *
   * 只把 `24000002`（NOT_FOUND）当作正常路径（首次运行）；
   * **其它错误码必须往上抛** —— 无条件吞异常会把"权限不足""资产库不可用"
   * 这类真实问题伪装成"首次运行"，从而静默生成新密钥、
   * 让已加密的 token 全部解不开。
   */
  private static async loadKeyBytes(): Promise<Uint8Array | null> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, TokenCipher.stringToUint8(TokenCipher.ALIAS));
    // 必须显式要 ALL —— 只给 ATTRIBUTES 时返回值里**不含 SECRET**
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    let results: Array<asset.AssetMap>;
    try {
      results = await asset.query(query);
    } catch (error) {
      const typed = error as BusinessErrorLike;
      if (typed.code === 24000002) {
        return null;   // 首次运行，尚无密钥
      }
      throw error as Error;
    }
    if (results.length === 0) {
      return null;
    }
    const secret: Uint8Array | undefined =
      results[0].get(asset.Tag.SECRET) as Uint8Array | undefined;
    return secret !== undefined && secret.length > 0 ? secret : null;
  }

  /**
   * 把密钥字节写进资产库（幂等覆盖）。
   *
   * 用 `CONFLICT_RESOLUTION = OVERWRITE` **一次 `add`** 完成覆盖，
   * 而不是 `remove` + `add` —— 后者**非原子**：两步之间进程崩溃就会
   * 永久丢失密钥，导致所有已加密的 token 再也解不开。
   */
  private static async storeKeyBytes(raw: Uint8Array): Promise<void> {
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, TokenCipher.stringToUint8(TokenCipher.ALIAS));
    attributes.set(asset.Tag.SECRET, raw);
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    // 默认是 THROW_ERROR：同 alias 重复 add 会抛 24000003
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attributes);
  }

  private static stringToUint8(text: string): Uint8Array {
    return new util.TextEncoder().encodeInto(text);
  }
}

/** 只取用得到的字段，避免 import BusinessError 造成循环依赖。 */
interface BusinessErrorLike {
  code: number;
  message: string;
}
