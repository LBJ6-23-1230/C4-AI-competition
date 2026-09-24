import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

/**
 * 把相册 / 拍照得到的**图片 URI** 读成 **base64**。
 *
 * ## 为什么必须有这个
 *
 * 后端 `/api/agent/chat` 的 `image` 字段按 **base64** 解析
 * （`app/agent/chat_llm.py::_call_llm_with_image` 里拼的是
 * `data:{mime};base64,{image}`）。
 *
 * 而前端原先直接把**相册 URI**（`file://media/Photo/...`）当 `image` 发出去 ——
 * 两边对同一个字段的理解不一致：后端拿到的"base64"其实是一串 URI，
 * 拼进 data URL 之后模型根本看不到图片。
 * **表现为"拍照识别这条链路是断的"**，而且不报错（后端 `b64decode(validate=False)`
 * 会静默忽略非法字符），最难查。
 *
 * ## 约定
 * 失败一律返回**空串**，由调用方给出可读提示 —— 不抛异常、不假装成功。
 */
export class ImageEncoder {
  /** 与后端契约一致的上限（`app/api/chat.py` 的 `_MAX_IMAGE_CHARS` 是 5MB）。 */
  private static readonly MAX_BYTES: number = 4 * 1024 * 1024;

  /**
   * 读取 URI 指向的图片并编码为 base64。
   *
   * @returns base64 字符串；读取失败或超过上限时返回空串。
   */
  static async toBase64(uri: string): Promise<string> {
    const target: string = (uri ?? '').trim();
    if (target.length === 0) {
      return '';
    }
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(target, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      const size: number = stat.size;
      if (size <= 0 || size > ImageEncoder.MAX_BYTES) {
        return '';
      }
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const read: number = fileIo.readSync(file.fd, buffer);
      if (read <= 0) {
        return '';
      }
      // 读满才编码：`readSync` 允许短读，短读时尾部是空字节，
      // 直接编码会把一张图编成"图片 + 一片空白"。
      const bytes: Uint8Array = read === size
        ? new Uint8Array(buffer)
        : new Uint8Array(buffer.slice(0, read));
      const helper: util.Base64Helper = new util.Base64Helper();
      return helper.encodeToStringSync(bytes);
    } catch (error) {
      return '';
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (closeError) {
          // 关闭失败无需上报，文件描述符会随进程回收
        }
      }
    }
  }

  /** 给人看的失败原因（调用方据此提示，不要自己编文案）。 */
  static describeFailure(): string {
    return '图片读取失败或超过 4MB 上限，请换一张重试。';
  }

  /**
   * 读取**应用内置**的示例图片（`resources/base/media/`）并编码为 base64。
   *
   * ## 为什么要它（这不是"假数据"）
   *
   * 演示链路「拍一道错题 → 识别 → 针对性练」依赖**相册里得有图**，
   * 而模拟器与新设备的相册通常是空的 —— 评委现场拿不到图就演示不了。
   * 内置一张示例错题图，点一下走的是**完全相同的真实识别链路**
   * （图片 → base64 → Qwen-VL → 结构化知识点），只是图从相册换成了内置资源。
   *
   * ⚠️ 界面上必须**标明这是内置示例**，不能让评委以为是现场拍的。
   */
  static fromResource(context: common.Context, mediaId: number): string {
    try {
      const bytes: Uint8Array = context.resourceManager.getMediaContentSync(mediaId);
      if (bytes === undefined || bytes.length === 0 || bytes.length > ImageEncoder.MAX_BYTES) {
        return '';
      }
      const helper: util.Base64Helper = new util.Base64Helper();
      return helper.encodeToStringSync(bytes);
    } catch (error) {
      return '';
    }
  }
}
