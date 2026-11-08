/**
 * VoiceRecorder —— 语音消息录制（P1）
 *
 * 契约见 vault: 04-Projects/03-XiaoQ/20261108_小QAPP语音消息功能_V3_施工版.md §3.4
 *
 * ⚠️ 三个必踩的坑（都已处理，改代码前先读）：
 *   1. `AVRecorderConfig.url` 只接受 **`fd://<fd>`**，给文件路径直接报错。
 *      fd 由 fs.openSync 拿，stop 后必须 closeSync。
 *   2. teardown 顺序必须是 stop → reset → release → closeSync。
 *      release 之前 close 会让 recorder 还在写已关闭的 fd。
 *      且必须挂 `on('error')` —— 切后台/来电被系统抢麦走的就是这条。
 *   3. 模拟器上 AVRecorder **录不出东西**（实测 stop() 抛 5400103 IO error，
 *      连 files 目录都不生成）。录音功能只能在真机验证。
 */

import { media } from '@kit.MediaKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'VoiceRecorder';
const MIN_DURATION_MS: number = 1000;
const MAX_DURATION_MS: number = 60000;

/** 录制结果 */
export class RecResult {
  /** 沙箱内文件绝对路径 */
  path: string = '';
  /** 文件名（上传时用，服务端按原名存） */
  name: string = '';
  /** 录音时长（毫秒，客户端自计） */
  durationMs: number = 0;
}

export class VoiceRecorder {
  private rec: media.AVRecorder | undefined = undefined;
  private fd: number = -1;
  private path: string = '';
  private name: string = '';
  private startedAt: number = 0;
  private started: boolean = false;
  private errorMsg: string = '';

  /** 麦克风权限（user_grant）。⚠️ 必须在用户点击的调用栈里申请 */
  public async ensurePermission(ctx: common.UIAbilityContext): Promise<boolean> {
    try {
      const at = abilityAccessCtrl.createAtManager();
      const res = await at.requestPermissionsFromUser(ctx, ['ohos.permission.MICROPHONE']);
      const ok: boolean = res.authResults.length > 0 && res.authResults[0] === 0;
      hilog.info(0x0001, TAG, 'mic permission granted=%{public}s', String(ok));
      return ok;
    } catch (e) {
      const be = e as BusinessError;
      hilog.error(0x0001, TAG, 'requestPermission failed code=%{public}d msg=%{public}s',
        be.code, be.message);
      return false;
    }
  }

  public isRecording(): boolean {
    return this.started;
  }

  public lastError(): string {
    return this.errorMsg;
  }

  /** 开始录音。返回是否成功进入 started 状态 */
  public async start(ctx: common.UIAbilityContext): Promise<boolean> {
    this.errorMsg = '';
    const dir: string = ctx.filesDir + '/voice';
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
    } catch (e) {
      try {
        fs.mkdirSync(dir);
      } catch (x) {
        hilog.error(0x0001, TAG, 'mkdir voice failed');
      }
    }

    // 文件名带 4 位随机后缀：服务端按原名存储，快速撤回重录会撞名静默覆盖
    const stamp: number = Date.now();
    const rnd: number = Math.floor(Math.random() * 10000);
    this.name = 'voice_' + stamp.toString() + '_' + rnd.toString() + '.m4a';
    this.path = dir + '/' + this.name;

    try {
      this.fd = fs.openSync(this.path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC).fd;

      this.rec = await media.createAVRecorder();
      this.rec.on('error', (err: BusinessError): void => {
        // 切后台 / 来电被系统抢麦会走这里
        hilog.error(0x0001, TAG, 'recorder onError code=%{public}d msg=%{public}s',
          err.code, err.message);
        this.errorMsg = '录音被中断（' + err.code.toString() + '）';
        this.started = false;
      });

      const profile: media.AVRecorderProfile = {
        audioBitrate: 64000,
        audioChannels: 1,
        audioCodec: media.CodecMimeType.AUDIO_AAC,
        audioSampleRate: 16000,
        fileFormat: media.ContainerFormatType.CFT_MPEG_4A
      };
      const config: media.AVRecorderConfig = {
        audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC,
        profile: profile,
        url: 'fd://' + this.fd.toString()
      };

      await this.rec.prepare(config);
      await this.rec.start();
      this.startedAt = Date.now();
      this.started = true;
      hilog.info(0x0001, TAG, 'recording started %{public}s', this.name);
      return true;
    } catch (e) {
      const be = e as BusinessError;
      this.errorMsg = be.code.toString() + ' ' + be.message;
      hilog.error(0x0001, TAG, 'start failed code=%{public}d msg=%{public}s',
        be.code, be.message);
      await this.teardown();
      return false;
    }
  }

  /**
   * 停止录音并返回结果。
   * 太短（<1s）或失败返回 null，调用方据此提示。
   */
  public async stop(): Promise<RecResult | null> {
    if (!this.started) {
      await this.teardown();
      return null;
    }
    const durationMs: number = Date.now() - this.startedAt;
    await this.teardown();

    if (durationMs < MIN_DURATION_MS) {
      this.removeFile(this.path);
      hilog.info(0x0001, TAG, 'too short %{public}dms, discarded', durationMs);
      return null;
    }

    let size: number = 0;
    try {
      size = fs.statSync(this.path).size;
    } catch (e) {
      size = 0;
    }
    if (size < 1024) {
      // 模拟器上就是这个表现：文件存在但几乎是空的
      this.removeFile(this.path);
      this.errorMsg = '录音文件为空（模拟器不支持 AVRecorder 录音，请用真机）';
      hilog.error(0x0001, TAG, 'empty recording size=%{public}d', size);
      return null;
    }

    const out: RecResult = new RecResult();
    out.path = this.path;
    out.name = this.name;
    out.durationMs = Math.min(durationMs, MAX_DURATION_MS);
    hilog.info(0x0001, TAG, 'recording stop %{public}s %{public}dms %{public}dB',
      out.name, out.durationMs, size);
    return out;
  }

  /** 取消录音（上滑取消 / 页面销毁） */
  public async cancel(): Promise<void> {
    const p: string = this.path;
    await this.teardown();
    this.removeFile(p);
  }

  /** 幂等清理：stop → reset → release → closeSync（顺序不可颠倒） */
  private async teardown(): Promise<void> {
    const rec = this.rec;
    const wasStarted: boolean = this.started;
    this.rec = undefined;
    this.started = false;
    if (rec !== undefined) {
      try {
        if (wasStarted) {
          await rec.stop();
        }
      } catch (e) {
        hilog.error(0x0001, TAG, 'stop in teardown failed (ignored)');
      }
      try {
        await rec.reset();
      } catch (e) {
        // ignore
      }
      try {
        await rec.release();
      } catch (e) {
        // ignore
      }
    }
    if (this.fd >= 0) {
      try {
        fs.closeSync(this.fd);
      } catch (e) {
        // ignore
      }
      this.fd = -1;
    }
    this.startedAt = 0;
  }

  private removeFile(path: string): void {
    if (path.length === 0) {
      return;
    }
    try {
      fs.unlinkSync(path);
    } catch (e) {
      // ignore
    }
  }
}

export const voiceRecorder: VoiceRecorder = new VoiceRecorder();
