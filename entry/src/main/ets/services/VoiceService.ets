/**
 * VoiceService —— 语音消息的"上传 + 转写"编排（P1）
 *
 * 契约见 vault: 04-Projects/03-XiaoQ/20261108_小QAPP语音消息功能_V3_施工版.md §3.6
 *
 * 流程：录音文件（沙箱 files/voice/）→ 上传 /api/upload → POST /api/asr 转写
 *      → 返回 VoiceMeta（消息正文直接用转写文本发送）
 *
 * ⚠️ 为什么**不复用** mediaPicker.upload()（V3 评审 MoA-1 🔴2）：
 *    1) 它 finally 里无论成败都删沙箱临时文件 → 语音上传失败后"点重试"无文件可传；
 *    2) type 硬编码为 image/jpeg 或 application/octet-stream，传不了 audio/mp4；
 *    3) 签名要求 PickedItem，录音结果不是 PickedItem。
 *    所以这里单独写一份，失败**保留源文件**。
 *
 * ⚠️ request.uploadFile 只接受 `internal://cache/<文件名>` 这种内部 URI
 *    （给绝对路径会报 GetInternalPath failed），所以先把文件复制到 cacheDir
 *    再上传，传完删掉 cache 副本、保留 files 原件（本地回放/重试用）。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { request } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { rest } from '../core/HermesRest.ets';
import { apiConfig } from '../core/ApiConfig.ets';
import { VoiceMeta } from '../models/ChatModels.ets';
import { RecResult } from './VoiceRecorder.ets';

const TAG: string = 'VoiceService';

/** ASR 结果 */
class AsrResult {
  text: string = '';
  durationMs: number = 0;
}

/** P2：TTS 段 */
export class TtsSeg {
  idx: number = 0;
  text: string = '';
  url: string = '';
  durationMs: number = 0;
  /** ready | pending | failed */
  status: string = 'pending';
}

export class VoiceService {
  /**
   * 完整处理一条录音：上传 → 转写。失败返回 null（调用方提示可重试）。
   * ⚠️ 失败时**不删** rec.path，重试直接再调一次本方法即可。
   */
  public async process(ctx: common.Context, rec: RecResult): Promise<VoiceMeta | null> {
    const upName: string = await this.upload(ctx, rec.path, rec.name);
    if (upName.length === 0) {
      hilog.error(0x0001, TAG, 'upload failed, keep local file for retry: %{public}s', rec.path);
      return null;
    }
    const asr: AsrResult | null = await this.transcribe(upName);
    if (asr === null || asr.text.length === 0) {
      hilog.error(0x0001, TAG, 'asr failed for %{public}s', upName);
      return null;
    }
    const meta: VoiceMeta = {
      url: '/api/upload/' + upName,
      durationMs: asr.durationMs > 0 ? asr.durationMs : rec.durationMs,
      transcript: asr.text,
      isUserVoice: true,
      localPath: rec.path
    };
    hilog.info(0x0001, TAG, 'voice ready %{public}s %{public}dms "%{public}s"',
      upName, meta.durationMs, meta.transcript);
    return meta;
  }

  /** 上传到 /api/upload，返回文件名；失败返回空串（源文件保留） */
  private async upload(ctx: common.Context, localPath: string, name: string): Promise<string> {
    let cachePath: string = '';
    let copied: boolean = false;
    try {
      cachePath = ctx.cacheDir + '/' + name;
      const src: fs.File = fs.openSync(localPath, fs.OpenMode.READ_ONLY);
      const dst: fs.File = fs.openSync(cachePath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.copyFileSync(src.fd, dst.fd);
      fs.closeSync(dst);
      fs.closeSync(src);
      copied = true;

      const headers: Record<string, string> = {};
      headers['Authorization'] = 'Bearer ' + apiConfig.getApiKey();

      const files: Array<request.File> = [{
        filename: name,
        name: 'file',
        uri: 'internal://cache/' + name,
        type: 'audio/mp4'
      }];
      const data: Array<request.RequestData> = [];
      const cfg: request.UploadConfig = {
        url: rest.getBaseUrl() + '/api/upload',
        header: headers,
        method: 'POST',
        files: files,
        data: data
      };

      const task: request.UploadTask = await request.uploadFile(ctx, cfg);
      // ⚠️ 不要用 TaskState.responseCode 判成败（真机实测服务端返回 200 它给 0），
      //    以 complete / fail 事件为准。
      const ok: boolean = await new Promise<boolean>((resolve) => {
        task.on('complete', (): void => {
          resolve(true);
        });
        task.on('fail', (states: Array<request.TaskState>) => {
          const rc: number = states.length > 0 && states[0].responseCode !== undefined
            ? states[0].responseCode : -1;
          hilog.error(0x0001, TAG, 'upload fail event rc=%{public}d', rc);
          resolve(false);
        });
      });
      if (!ok) {
        return '';
      }
      return name;
    } catch (e) {
      const be = e as BusinessError;
      hilog.error(0x0001, TAG, 'upload threw code=%{public}d msg=%{public}s',
        be.code, be.message);
      return '';
    } finally {
      // 只删 cache 副本；filesDir 原件保留（重试 + 本地回放）
      if (copied && cachePath.length > 0) {
        try {
          fs.unlinkSync(cachePath);
        } catch (x) {
          // ignore
        }
      }
    }
  }

  /** 调服务端 /api/asr 转写已上传的音频 */
  private async transcribe(name: string): Promise<AsrResult | null> {
    try {
      const body: Record<string, Object> = { 'name': name };
      const raw: Record<string, Object> = await rest.post(
        '/api/asr', body) as Record<string, Object>;
      const text: string = raw['transcript'] !== undefined ? String(raw['transcript']) : '';
      const dur: number = raw['duration_ms'] !== undefined
        ? Number(raw['duration_ms']) : 0;
      if (text.trim().length === 0) {
        return null;
      }
      const out: AsrResult = new AsrResult();
      out.text = text.trim();
      out.durationMs = isNaN(dur) ? 0 : dur;
      return out;
    } catch (e) {
      const be = e as BusinessError;
      hilog.error(0x0001, TAG, 'asr threw code=%{public}d msg=%{public}s',
        be.code, be.message);
      return null;
    }
  }
  // ─────────────────── P2：TTS 分段准备 / 轮询 ───────────────────

  /**
   * 请求服务端分段合成一条回复的语音。
   * 服务端已异步化：立刻返回段列表（status=pending/ready），后台逐段合成。
   */
  public async prepareTts(text: string, turnKey: string): Promise<TtsSeg[]> {
    const body: Record<string, Object> = {
      'text': text,
      'voice': 'claire',
      'turn_key': turnKey
    };
    try {
      const raw: Record<string, Object> = await rest.post(
        '/api/tts/prepare', body) as Record<string, Object>;
      return this.parseSegs(raw);
    } catch (e) {
      const be = e as BusinessError;
      hilog.error(0x0001, TAG, 'prepareTts failed code=%{public}d msg=%{public}s',
        be.code, be.message);
      return [];
    }
  }

  /** 轮询某轮的段状态（播放器 BUFFERING 时用） */
  public async fetchSegments(turnKey: string): Promise<TtsSeg[]> {
    try {
      const raw: Record<string, Object> = await rest.get(
        '/api/tts/segments?turn=' + encodeURIComponent(turnKey)) as Record<string, Object>;
      return this.parseSegs(raw);
    } catch (e) {
      hilog.error(0x0001, TAG, 'fetchSegments failed');
      return [];
    }
  }

  private parseSegs(raw: Record<string, Object>): TtsSeg[] {
    const out: TtsSeg[] = [];
    const arr: Object | undefined = raw['segments'];
    if (arr === undefined || arr === null) {
      return out;
    }
    const list: Array<Record<string, Object>> = arr as Array<Record<string, Object>>;
    for (let i: number = 0; i < list.length; i++) {
      const o: Record<string, Object> = list[i];
      const seg: TtsSeg = new TtsSeg();
      seg.idx = o['idx'] !== undefined ? Number(o['idx']) : i;
      seg.text = o['text'] !== undefined ? String(o['text']) : '';
      seg.url = o['url'] !== undefined ? String(o['url']) : '';
      seg.durationMs = o['duration_ms'] !== undefined ? Number(o['duration_ms']) : 0;
      seg.status = o['status'] !== undefined ? String(o['status']) : 'pending';
      out.push(seg);
    }
    return out;
  }
}

export const voiceService: VoiceService = new VoiceService();
