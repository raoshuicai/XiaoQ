/**
 * VoiceInput —— 系统语音识别封装（S22）
 *
 * 用 HarmonyOS 自带的 speechRecognizer（@kit.CoreSpeechKit），
 * **不需要任何后端 ASR 接口** —— 直接把手机麦克风听到的话转成文字。
 *
 * ⚠️ 参数取值（查 SDK d.ts 得到，别凭直觉）：
 *   CreateEngineParams.online —— **0 = 在线识别，1 = 离线识别**（与直觉相反）
 *   语言用 'zh-CN'
 *
 * ⚠️ 权限：需要在 module.json5 声明 ohos.permission.MICROPHONE（已加）。
 *
 * ⚠️ 权限是 user_grant 级别，必须在**运行时**再申请一次（仅声明不够）：
 *   模块声明 + abilityAccessCtrl.requestPermissionsFromUser 两步都要做。
 */

import { speechRecognizer } from '@kit.CoreSpeechKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 识别会话 ID（引擎要求每次 start 传一个）*/
const VOICE_SESSION_ID: string = 'xiaoq-voice-session';
const VOICE_TAG: string = 'Voice';

/**
 * 引擎参数。
 *
 * ⚠️ 两个都是实测/查证踩出来的坑（2026-09-19）：
 *   ① `online` 的语义**反直觉**：**1 = 离线，0 = 在线**，
 *      而且**当前只支持离线引擎** —— 传 0 会直接 createEngine 失败并报
 *      `1002200001 Asr CreateEngine 失败`（官方对该码的解释：语种不支持/模式不支持/
 *      初始化超时/资源不存在）。
 *   ② extraParams 的 key 是 `locate` + `recognizerMode`（不是 recognitionMode，
 *      也没有 vadBegin/maxAudioDuration 这些）。recognizerMode: 'short' = 短语音(≤60s)，
 *      'long' = 长语音(≤8h)。
 */
const ENGINE_EXTRA_PARAMS: Record<string, Object> = {
  'locate': 'CN',
  'recognizerMode': 'short'
};

/** 录音参数 —— 与官方示例一致 */
const AUDIO_INFO: speechRecognizer.AudioInfo = {
  audioType: 'pcm',
  sampleRate: 16000,
  soundChannel: 1,
  sampleBit: 16
};

export class VoiceInput {
  private engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private listening: boolean = false;
  /** 累积的最终文本（多次 onResult 拼接）*/
  private finalText: string = '';

  public isListening(): boolean {
    return this.listening;
  }

  /** 运行时申请麦克风权限；已授权则直接返回 true */
  public async ensurePermission(ctx: common.Context): Promise<boolean> {
    try {
      const mgr: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const perms: Permissions[] = ['ohos.permission.MICROPHONE'];
      const res = await mgr.requestPermissionsFromUser(ctx, perms);
      const granted: boolean = res.authResults.length > 0 && res.authResults[0] === 0;
      return granted;
    } catch (e) {
      hilog.error(0x0001, VOICE_TAG, 'request permission failed: %{public}s', (e as BusinessError).message);
      return false;
    }
  }

  /**
   * 开始识别。
   * @param onPartial 实时中间结果（用于边说边显示）
   * @param onFinal   最终结果（说完一句）
   * @param onError   出错信息
   */
  public async start(onPartial: (t: string) => void,
                     onFinal: (t: string) => void,
                     onError: (msg: string) => void): Promise<void> {
    if (this.listening) {
      return;
    }
    this.finalText = '';

    try {
      if (this.engine === null) {
        const createParams: speechRecognizer.CreateEngineParams = {
          language: 'zh-CN',
          online: 1,                    // ⚠️ 1 = 离线（只支持离线引擎）；0=在线会 createEngine 失败
          extraParams: ENGINE_EXTRA_PARAMS
        };
        hilog.error(0x0001, VOICE_TAG,
          'createEngine language=zh-CN online=1 extra=%{public}s',
          JSON.stringify(ENGINE_EXTRA_PARAMS));
        this.engine = await speechRecognizer.createEngine(createParams);
        hilog.error(0x0001, VOICE_TAG, 'createEngine OK');
      }
      const eng: speechRecognizer.SpeechRecognitionEngine = this.engine;

      const listener: speechRecognizer.RecognitionListener = {
        onStart: (sessionId: string, eventMessage: string): void => {
          hilog.error(0x0001, VOICE_TAG, 'onStart %{public}s', eventMessage);
        },
        onEvent: (sessionId: string, eventCode: number, eventMessage: string): void => {
          hilog.error(0x0001, VOICE_TAG, 'onEvent code=%{public}d %{public}s', eventCode, eventMessage);
        },
        onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
          const text: string = result.result ?? '';
          if (text.length === 0) {
            return;
          }
          if (result.isFinal) {
            this.finalText = text;
            onFinal(text);
          } else {
            onPartial(text);
          }
        },
        onComplete: (sessionId: string, eventMessage: string): void => {
          hilog.error(0x0001, VOICE_TAG, 'onComplete %{public}s', eventMessage);
          this.listening = false;
        },
        onError: (sessionId: string, errorCode: number, errorMessage: string): void => {
          hilog.error(0x0001, VOICE_TAG, 'onError code=%{public}d msg=%{public}s', errorCode, errorMessage);
          this.listening = false;
          onError('识别失败(' + errorCode + ')');
        }
      };
      eng.setListener(listener);

      const startParams: speechRecognizer.StartParams = {
        sessionId: VOICE_SESSION_ID,
        audioInfo: AUDIO_INFO
        // ⚠️ 不要再往这里塞 recognitionMode/vadBegin/maxAudioDuration ——
        //    那些 key 名是我早期猜的，实际会被忽略或导致失败；引擎参数走
        //    CreateEngineParams.extraParams（locate + recognizerMode）。
      };
      eng.startListening(startParams);
      this.listening = true;
      hilog.error(0x0001, VOICE_TAG, 'startListening issued');
    } catch (e) {
      this.listening = false;
      const err = e as BusinessError;
      hilog.error(0x0001, VOICE_TAG,
        'start FAILED code=%{public}d msg=%{public}s', err.code, err.message);
      onError('语音识别启动失败(' + err.code + ')：' + err.message);
    }
  }

  /** 停止识别（说完后调用）*/
  public stop(): void {
    if (!this.listening || this.engine === null) {
      return;
    }
    try {
      this.engine.finish(VOICE_SESSION_ID);
    } catch (e) {
      hilog.error(0x0001, VOICE_TAG, 'stop failed: %{public}s', (e as BusinessError).message);
    }
    this.listening = false;
  }

  public destroy(): void {
    if (this.engine !== null) {
      try {
        this.engine.shutdown();
      } catch (e) {
        // ignore
      }
      this.engine = null;
    }
    this.listening = false;
  }
}

export const voiceInput: VoiceInput = new VoiceInput();
