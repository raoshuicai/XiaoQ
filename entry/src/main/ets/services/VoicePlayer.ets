/**
 * VoicePlayer —— 分段队列播放（P2）
 *
 * 契约见 vault: 04-Projects/03-XiaoQ/20261108_小QAPP语音消息功能_V3_施工版.md §3.5
 *
 * 为什么不是一个 URL 播到底：服务端按句分段合成，第一段 ready 就能开播（实测 1.67s），
 * 后面几段在播放第一段的这段时间里合成完毕 —— 整段合成要等 5-9 秒才能出声。
 *
 * ⚠️ 两个必须守住的竞态（V3 评审 MoA-2 #6/#7）：
 *   1. **playbackSessionId 单调递增**：stop() 之后，上一段 AVPlayer 的 'completed'
 *      回调可能还在路上。没有这个校验，它会把刚清空的队列当成"该播下一段"，
 *      导致旧音频复活 / 双音重叠。
 *   2. **BUFFERING 态**：第 N 段播完而第 N+1 段还没合成好时，队列是空的。若直接判
 *      FINISHED，就会出现"播完第一句突然停了，得再点一次"（下溢哑火）。正确做法是
 *      进 BUFFERING 并轮询，新段一到自动点火。
 */

import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'VoicePlayer';

/** 轮询段状态的间隔 / 最大次数（500ms × 24 ≈ 12s） */
const POLL_INTERVAL_MS: number = 500;
const POLL_MAX: number = 24;

/** 一段音频 */
export class VoiceSeg {
  idx: number = 0;
  text: string = '';
  /** 相对路径，如 /api/tts/segments/<turn>/0.mp3 */
  url: string = '';
  durationMs: number = 0;
  /** ready | pending | failed */
  status: string = 'pending';
}

/** 播放状态回调 */
export interface VoicePlayerHooks {
  /** state: 'playing' | 'buffering' | 'finished' | 'error' */
  onState: (state: string, segIdx: number) => void;
  onError: (msg: string) => void;
}

export class VoicePlayer {
  private player: media.AVPlayer | undefined = undefined;
  /** ⚠️ 竞态守卫：每次 play/stop 自增，回调里比对，不一致直接 return */
  private sessionId: number = 0;
  private queue: VoiceSeg[] = [];
  private cursor: number = 0;
  private turnKey: string = '';
  private hooks: VoicePlayerHooks | undefined = undefined;
  private polling: boolean = false;
  private pollCount: number = 0;
  private pollTimer: number = -1;
  /** 拉取最新段列表的回调（由 ChatPage 注入，避免这里依赖 rest） */
  private fetchSegs: ((turn: string) => Promise<VoiceSeg[]>) | undefined = undefined;
  private toAbsolute: ((relative: string) => string) | undefined = undefined;

  public bind(hooks: VoicePlayerHooks,
              fetchSegs: (turn: string) => Promise<VoiceSeg[]>,
              toAbsolute: (relative: string) => string): void {
    this.hooks = hooks;
    this.fetchSegs = fetchSegs;
    this.toAbsolute = toAbsolute;
  }

  public isPlaying(turnKey: string): boolean {
    return this.turnKey === turnKey && this.turnKey !== '';
  }

  public currentTurn(): string {
    return this.turnKey;
  }

  /**
   * 开始播放一轮。
   * @param turnKey 轮次标识（= 这条回复的 msg_id，也是服务端的 turn_key）
   * @param segments 服务端 prepare 返回的段列表（可能含 pending）
   */
  public async start(turnKey: string, segments: VoiceSeg[]): Promise<void> {
    await this.stop();
    this.sessionId = this.sessionId + 1;
    const sid: number = this.sessionId;
    this.turnKey = turnKey;
    this.queue = segments.slice(0);
    this.cursor = 0;
    this.pollCount = 0;
    hilog.info(0x0001, TAG, 'start turn=%{public}s segs=%{public}d',
      turnKey, this.queue.length);
    await this.playNext(sid);
  }

  /** 停止并释放。可重复调用（幂等）。 */
  public async stop(): Promise<void> {
    this.sessionId = this.sessionId + 1;     // ⚠️ 先自增：让所有在途回调失效
    this.stopPoll();
    this.queue = [];
    this.cursor = 0;
    this.turnKey = '';
    const p = this.player;
    this.player = undefined;
    if (p !== undefined) {
      try {
        await p.stop();
      } catch (e) {
        // 未 playing 时 stop 会抛，忽略
      }
      try {
        await p.reset();
      } catch (e) {
        // ignore
      }
      try {
        await p.release();
      } catch (e) {
        // ignore
      }
    }
  }

  // ─────────────────────────── 内部 ───────────────────────────

  /** 播下一段；没有 ready 的段就轮询等 */
  private async playNext(sid: number): Promise<void> {
    if (sid !== this.sessionId) {
      return;
    }
    // 找 cursor 之后第一个 ready 的段
    let target: VoiceSeg | undefined = undefined;
    for (let i: number = this.cursor; i < this.queue.length; i++) {
      if (this.queue[i].status === 'ready') {
        target = this.queue[i];
        this.cursor = i + 1;
        break;
      }
      if (this.queue[i].status === 'pending') {
        break;              // 保持顺序：前面的还没好，不能跳过后面的
      }
      // failed 的跳过
      this.cursor = i + 1;
    }

    if (target === undefined) {
      // 队列暂时空了：还有 pending 就进 BUFFERING 等，否则结束
      const hasPending: boolean = this.queueHasPending();
      if (hasPending) {
        this.emit('buffering', this.cursor);
        this.schedulePoll(sid);
      } else {
        this.finish();
      }
      return;
    }

    await this.playSeg(sid, target);
  }

  private queueHasPending(): boolean {
    for (let i: number = 0; i < this.queue.length; i++) {
      if (this.queue[i].status === 'pending') {
        return true;
      }
    }
    return false;
  }

  private async playSeg(sid: number, seg: VoiceSeg): Promise<void> {
    const raw: string = this.toAbsolute !== undefined ? this.toAbsolute(seg.url) : seg.url;
    try {
      const p: media.AVPlayer = await media.createAVPlayer();
      if (sid !== this.sessionId) {
        try {
          await p.release();
        } catch (e) {
          // ignore
        }
        return;
      }
      this.player = p;

      // ⚠️ AVPlayer 是**状态机驱动**的，必须按 idle → (设 url) → initialized → prepared
      //    → playing 走。直接 createAVPlayer 后立刻 prepare() 会报
      //    5400102 "current state is not stopped or initialized, unsupport prepare
      //    operation"（真机/模拟器都踩过）。所以这里全部用 stateChange 回调串起来，
      //    顺序 await 是行不通的。
      p.on('stateChange', (state: media.AVPlayerState) => {
        if (sid !== this.sessionId) {
          return;                       // ⚠️ 旧 session 的回调一律丢弃
        }
        if (state === 'initialized') {
          p.prepare().catch((e: BusinessError) => {
            hilog.error(0x0001, TAG, 'prepare failed seg=%{public}d code=%{public}d',
              seg.idx, e.code);
            this.releaseCurrent();
            this.playNext(sid);
          });
        } else if (state === 'prepared') {
          p.play().catch((e: BusinessError) => {
            hilog.error(0x0001, TAG, 'play failed seg=%{public}d code=%{public}d',
              seg.idx, e.code);
            this.releaseCurrent();
            this.playNext(sid);
          });
        } else if (state === 'playing') {
          this.emit('playing', seg.idx);
          hilog.info(0x0001, TAG, 'playing seg=%{public}d url=%{public}s', seg.idx, raw);
        } else if (state === 'completed') {
          this.releaseCurrent();
          this.playNext(sid);
        }
      });
      p.on('error', (err: BusinessError) => {
        if (sid !== this.sessionId) {
          return;
        }
        hilog.error(0x0001, TAG, 'player error seg=%{public}d code=%{public}d msg=%{public}s',
          seg.idx, err.code, err.message);
        this.releaseCurrent();
        // 单段失败不中断整轮：跳过它继续
        this.playNext(sid);
      });

      // 设 url 会触发 idle → initialized，后续由回调推进
      p.url = raw;
    } catch (e) {
      const be = e as BusinessError;
      hilog.error(0x0001, TAG, 'playSeg failed seg=%{public}d code=%{public}d msg=%{public}s',
        seg.idx, be.code, be.message);
      if (sid === this.sessionId) {
        this.releaseCurrent();
        await this.playNext(sid);        // 失败也继续下一段
      }
    }
  }

  private releaseCurrent(): void {
    const p = this.player;
    this.player = undefined;
    if (p !== undefined) {
      try {
        p.release();
      } catch (e) {
        // ignore
      }
    }
  }

  /** 轮询服务端段状态，新段 ready 就自动点火（BUFFERING 唤醒） */
  private schedulePoll(sid: number): void {
    if (this.polling || this.fetchSegs === undefined || this.turnKey === '') {
      return;
    }
    this.polling = true;
    this.stopPoll();
    this.pollTimer = setTimeout(() => {
      this.pollTimer = -1;
      this.doPoll(sid);
    }, POLL_INTERVAL_MS);
  }

  private async doPoll(sid: number): Promise<void> {
    if (sid !== this.sessionId) {
      this.polling = false;
      return;
    }
    this.pollCount = this.pollCount + 1;
    if (this.pollCount > POLL_MAX) {
      this.polling = false;
      hilog.info(0x0001, TAG, 'poll timeout, finish partial');
      this.finish();
      return;
    }
    try {
      const fetcher = this.fetchSegs;
      if (fetcher === undefined) {
        this.polling = false;
        this.finish();
        return;
      }
      const latest: VoiceSeg[] = await fetcher(this.turnKey);
      if (sid !== this.sessionId) {
        this.polling = false;
        return;
      }
      // 用服务端状态更新本地队列（按 idx 对齐，保持段顺序）
      for (let i: number = 0; i < latest.length; i++) {
        const s: VoiceSeg = latest[i];
        for (let j: number = 0; j < this.queue.length; j++) {
          if (this.queue[j].idx === s.idx) {
            this.queue[j].status = s.status;
            this.queue[j].durationMs = s.durationMs;
            this.queue[j].url = s.url;
            break;
          }
        }
      }
    } catch (e) {
      hilog.error(0x0001, TAG, 'poll failed');
    }
    this.polling = false;
    if (sid !== this.sessionId) {
      return;
    }
    await this.playNext(sid);
  }

  private stopPoll(): void {
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
    this.polling = false;
  }

  private finish(): void {
    this.turnKey = '';
    this.queue = [];
    this.cursor = 0;
    this.emit('finished', -1);
  }

  private emit(state: string, segIdx: number): void {
    if (this.hooks !== undefined) {
      this.hooks.onState(state, segIdx);
    }
  }
}

export const voicePlayer: VoicePlayer = new VoicePlayer();
