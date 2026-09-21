import { audio } from '@kit.AudioKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';

export class VoiceInputCallbacks {
  onStateChange: (listening: boolean) => void;
  onText: (text: string, isFinal: boolean) => void;
  onError: (message: string) => void;

  constructor(
    onStateChange: (listening: boolean) => void,
    onText: (text: string, isFinal: boolean) => void,
    onError: (message: string) => void
  ) {
    this.onStateChange = onStateChange;
    this.onText = onText;
    this.onError = onError;
  }
}

/**
 * Single-page speech-to-text controller.
 *
 * CoreSpeechKit accepts PCM frames rather than opening the microphone itself, so this service
 * keeps the recognizer and AudioCapturer lifecycles together. The engine is reused between turns
 * and released only when the chat page disappears.
 */
export class VoiceInputService {
  private engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private capturer: audio.AudioCapturer | null = null;
  private callbacks: VoiceInputCallbacks | null = null;
  private sessionId: string = '';
  private listening: boolean = false;
  private finishTimer: number = -1;

  isListening(): boolean {
    return this.listening;
  }

  async start(callbacks: VoiceInputCallbacks): Promise<void> {
    if (this.listening) return;
    this.callbacks = callbacks;
    try {
      const engine: speechRecognizer.SpeechRecognitionEngine = await this.ensureEngine();
      if (engine.isBusy()) {
        callbacks.onError('语音识别正在处理上一段内容，请稍后再试。');
        return;
      }

      this.sessionId = `zhixue-voice-${Date.now()}`;
      this.capturer = await audio.createAudioCapturer({
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: {
          source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION,
          capturerFlags: 0
        }
      });

      engine.startListening({
        sessionId: this.sessionId,
        audioInfo: {
          audioType: 'pcm',
          sampleRate: 16000,
          soundChannel: 1,
          sampleBit: 16
        }
      });
      this.capturer.on('readData', (buffer: ArrayBuffer) => this.writePcm(buffer));
      await this.capturer.start();
      this.listening = true;
      callbacks.onStateChange(true);
      this.finishTimer = setTimeout(() => { void this.stop(true); }, 15000);
    } catch (error) {
      await this.stopCapture();
      this.listening = false;
      callbacks.onStateChange(false);
      callbacks.onError(this.readableError(error));
    }
  }

  async stop(requestFinalResult: boolean = true): Promise<void> {
    const activeSession: string = this.sessionId;
    if (!this.listening && this.capturer === null) return;
    this.listening = false;
    this.clearFinishTimer();
    await this.stopCapture();
    this.callbacks?.onStateChange(false);
    if (requestFinalResult && activeSession.length > 0 && this.engine !== null) {
      try {
        this.engine.finish(activeSession);
      } catch (error) {
        this.callbacks?.onError(this.readableError(error));
      }
    }
  }

  async dispose(): Promise<void> {
    await this.stop(false);
    if (this.engine !== null) {
      this.engine.shutdown();
      this.engine = null;
    }
    this.callbacks = null;
    this.sessionId = '';
  }

  private async ensureEngine(): Promise<speechRecognizer.SpeechRecognitionEngine> {
    if (this.engine !== null) return this.engine;
    const engine: speechRecognizer.SpeechRecognitionEngine = await speechRecognizer.createEngine({
      language: 'zh-CN',
      // SDK 依据（@hms.ai.speechRecognizer.d.ts）：
      //   "The value 0 indicates online, value 1 indicates offline."
      // 语义与字段名相反，极易写错。这里要的是**在线识别**：
      //   * 离线模式依赖设备本地语言包，模拟器/部分真机未预置会直接失败；
      //   * 在线识别准确率更高，且无需用户额外下载语言包。
      online: 0
    });
    engine.setListener({
      onStart: (sessionId: string, eventMessage: string): void => {
        if (sessionId !== this.sessionId) return;
      },
      onEvent: (sessionId: string, eventCode: number, eventMessage: string): void => {
        if (sessionId !== this.sessionId) return;
      },
      onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
        if (sessionId !== this.sessionId || result.result.trim().length === 0) return;
        this.callbacks?.onText(result.result.trim(), result.isFinal || result.isLast);
      },
      onComplete: (sessionId: string, eventMessage: string): void => {
        if (sessionId !== this.sessionId) return;
        this.listening = false;
        this.clearFinishTimer();
        this.callbacks?.onStateChange(false);
      },
      onError: (sessionId: string, errorCode: number, errorMessage: string): void => {
        if (sessionId !== this.sessionId) return;
        this.listening = false;
        this.clearFinishTimer();
        void this.stopCapture();
        this.callbacks?.onStateChange(false);
        this.callbacks?.onError(this.recognitionError(errorCode, errorMessage));
      }
    });
    this.engine = engine;
    return engine;
  }

  private writePcm(buffer: ArrayBuffer): void {
    if (!this.listening || this.engine === null || this.sessionId.length === 0) return;
    const bytes: Uint8Array = new Uint8Array(buffer);
    let offset: number = 0;
    try {
      while (bytes.length - offset >= 640) {
        const frameSize: number = bytes.length - offset >= 1280 ? 1280 : 640;
        this.engine.writeAudio(this.sessionId, bytes.slice(offset, offset + frameSize));
        offset += frameSize;
      }
    } catch (error) {
      this.callbacks?.onError(this.readableError(error));
      void this.stop(false);
    }
  }

  private async stopCapture(): Promise<void> {
    const activeCapturer: audio.AudioCapturer | null = this.capturer;
    this.capturer = null;
    if (activeCapturer === null) return;
    try {
      activeCapturer.off('readData');
      if (activeCapturer.state === audio.AudioState.STATE_RUNNING) {
        await activeCapturer.stop();
      }
      await activeCapturer.release();
    } catch (error) {
      // Cleanup is best effort; the next recognition turn creates a fresh capturer.
    }
  }

  private clearFinishTimer(): void {
    if (this.finishTimer >= 0) {
      clearTimeout(this.finishTimer);
      this.finishTimer = -1;
    }
  }

  private recognitionError(code: number, detail: string): string {
    if (code === 1002200012) return '没有麦克风权限，请在系统设置中允许后重试。';
    if (code === 1002200006) return '语音识别服务正忙，请稍后重试。';
    if (code === 1002200001 || code === 1002200009) return '当前设备暂不支持语音识别，请使用真机或直接输入文字。';
    return detail.length > 0 ? `语音识别失败：${detail}` : '语音识别失败，请稍后重试。';
  }

  private readableError(error: Object): string {
    const raw: string = JSON.stringify(error);
    if (raw.includes('201') || raw.includes('1002200012')) {
      return '没有麦克风权限，请在系统设置中允许后重试。';
    }
    return '当前设备无法启动语音识别，请在真机上重试或直接输入文字。';
  }
}
