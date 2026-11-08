/**
 * VoicePlayer —— 分段队列播放（P2+ 双缓冲）
 *
 * 契约见 vault: 04-Projects/03-XiaoQ/20261108_小QAPP语音消息功能_V3_施工版.md §3.5
 *
 * 为什么不是一个 URL 播到底：服务端按句分段合成，第一段 ready 就能开播，
 * 后面几段在播放第一段的这段时间里合成完毕。
 *
 * ⚠️ 三道防线（每一道都对应一次实测踩坑）：
 *   1. **playbackSessionId 单调递增**：stop() 之后，上一段 AVPlayer 的 'completed'
 *      回调可能还在路上。没有这个校验，它会把刚清空的队列当成"该播下一段"，
 *      导致旧音频复活 / 双音重叠。
 *   2. **BUFFERING 态**：第 N 段播完而第 N+1 段还没合成好时，队列是空的。若直接判
 *      FINISHED，就会出现"播完第一句突然停了"（下溢哑火）。正确做法是进 BUFFERING
 *      并轮询，新段一到自动点火。
 *   3. **双缓冲预加载**：播第 N 段的同时，就把第 N+1 段 createAVPlayer + prepare 好。
 *      不预加载的话每段前都要「新建 player → 设 url → prepare → 播放」，实测每段
 *      多出 300ms~2s 的静默，听起来就是「读一句停一下」。
 *
 * ⚠️ AVPlayer 状态机：**不能** createAVPlayer 后直接 prepare()，会报
 *    5400102 "current state is not stopped or initialized"。必须
 *    idle →(设 url)→ initialized → prepared → playing，用 stateChange 串。
 */

import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'VoicePlayer';

/** 轮询段状态的间隔 / 最大次数（400ms × 30 ≈ 12s） */
const POLL_INTERVAL_MS: number = 400;
const POLL_MAX: number = 30;

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
  /** 双缓冲：已 prepare 好、等着接棒的下一段 */
  private prefetchPlayer: media.AVPlayer | undefined = undefined;
  private prefetchIdx: number = -1;
  private fetchSegs: ((turn: string) => Promise<VoiceSeg[]>) | undefined = undefined;
  private absUrl: ((relative: string) => string) | undefined = undefined;

  public bind(hooks: VoicePlayerHooks,
              fetchSegs: (turn: string) => Promise<VoiceSeg[]>,
              toAbsolute: (relative: string) => string): void {
    this.hooks = hooks;
    this.fetchSegs = fetchSegs;
    this.absUrl = toAbsolute;
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
    this.releasePrefetch();
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

  /** 播下一段；优先用预取好的 player（零准备延迟） */
  private async playNext(sid: number): Promise<void> {
    if (sid !== this.sessionId) {
      return;
    }
    // 找 cursor 之后第一个 ready 的段
    let target: VoiceSeg | undefined = undefined;
    for (let i: number = this.cursor; i < this.queue.length; i++) {
      const s: VoiceSeg = this.queue[i];
      if (s.status === 'ready') {
        target = s;
        this.cursor = i + 1;
        break;
      }
      if (s.status === 'pending') {
        break;              // 保持顺序：前面的还没好，不能跳过后面的
      }
      this.cursor = i + 1;  // failed 跳过
    }

    if (target === undefined) {
      if (this.queueHasPending()) {
        this.emit('buffering', this.cursor);
        this.schedulePoll(sid);
      } else {
        this.finish();
      }
      return;
    }

    // ⚠️ 收窄成 const：闭包里引用 let 变量时 ArkTS 仍按 possibly-undefined 处理
    const seg: VoiceSeg = target;

    // 双缓冲命中：直接用已 prepare 好的 player 起播
    if (this.prefetchIdx === seg.idx && this.prefetchPlayer !== undefined) {
      const p: media.AVPlayer = this.prefetchPlayer;
      this.prefetchPlayer = undefined;
      this.prefetchIdx = -1;
      this.player = p;
      hilog.info(0x0001, TAG, 'play seg=%{public}d (prefetched)', seg.idx);
      p.play().catch((e: BusinessError) => {
        hilog.error(0x0001, TAG, 'play failed seg=%{public}d code=%{public}d',
          seg.idx, e.code);
        this.releaseCurrent();
        this.playNext(sid);
      });
      // 起播后立刻预取再下一段
      this.prefetchNext(sid);
      return;
    }

    await this.playSeg(sid, seg);
  }

  private queueHasPending(): boolean {
    for (let i: number = 0; i < this.queue.length; i++) {
      if (this.queue[i].status === 'pending') {
        return true;
      }
    }
    return false;
  }

  /** 找 cursor 之后第一个 ready 段并预创建 player（不播放） */
  private async prefetchNext(sid: number): Promise<void> {
    if (this.prefetchPlayer !== undefined) {
      return;                     // 已有预取
    }
    let next: VoiceSeg | undefined = undefined;
    for (let i: number = this.cursor; i < this.queue.length; i++) {
      const s: VoiceSeg = this.queue[i];
      if (s.status === 'ready') {
        next = s;
        break;
      }
      if (s.status === 'pending') {
        // ⚠️ 下一段还没合成好 —— 不能就这么放弃：起一次轮询，等它 ready 后
        //    立刻回来预取。否则「当前段播完 → 现建 player → prepare」又回到
        //    每段几百毫秒的静默（实测 seg0→seg1 空了 5 秒就是这么来的）。
        this.schedulePoll(sid);
        return;
      }
    }
    if (next === undefined) {
      return;
    }
    const raw: string = this.absUrl !== undefined ? this.absUrl(next.url) : next.url;
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
      p.on('stateChange', (state: media.AVPlayerState) => {
        if (sid !== this.sessionId) {
          return;
        }
        if (state === 'initialized') {
          p.prepare().catch((e: BusinessError) => {
            hilog.error(0x0001, TAG, 'prefetch prepare failed seg=%{public}d code=%{public}d',
              next !== undefined ? next.idx : -1, e.code);
          });
        } else if (state === 'playing') {
          if (next !== undefined) {
            this.emit('playing', next.idx);
          }
        } else if (state === 'completed') {
          // 只有「已升级为当前播放器」才会走到这里
          this.releaseCurrent();
          this.playNext(sid);
        }
      });
      p.on('error', (err: BusinessError) => {
        if (sid !== this.sessionId) {
          return;
        }
        hilog.error(0x0001, TAG, 'prefetch player error code=%{public}d', err.code);
      });
      p.url = raw;
      this.prefetchPlayer = p;
      this.prefetchIdx = next.idx;
      hilog.info(0x0001, TAG, 'prefetch seg=%{public}d url=%{public}s', next.idx, raw);
    } catch (e) {
      const be = e as BusinessError;
      hilog.error(0x0001, TAG, 'prefetch failed code=%{public}d', be.code);
    }
  }

  private async playSeg(sid: number, seg: VoiceSeg): Promise<void> {
    const raw: string = this.absUrl !== undefined ? this.absUrl(seg.url) : seg.url;
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

      // ⚠️ AVPlayer 状态机：设 url 后才会到 initialized，此时才能 prepare。
      p.on('stateChange', (state: media.AVPlayerState) => {
        if (sid !== this.sessionId) {
          return;
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
          this.prefetchNext(sid);          // 起播即预取下一段
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
        this.playNext(sid);          // 单段失败跳过，不中断整轮
      });

      p.url = raw;
    } catch (e) {
      const be = e as BusinessError;
      hilog.error(0x0001, TAG, 'playSeg failed seg=%{public}d code=%{public}d msg=%{public}s',
        seg.idx, be.code, be.message);
      if (sid === this.sessionId) {
        this.releaseCurrent();
        await this.playNext(sid);
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

  private releasePrefetch(): void {
    const p = this.prefetchPlayer;
    this.prefetchPlayer = undefined;
    this.prefetchIdx = -1;
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
    // ⚠️ 当前还有段在播（player 未释放）时，轮询只负责「把下一段预取好」，
    //    绝不能调 playNext —— 那会让两段同时出声。
    if (this.player !== undefined) {
      await this.prefetchNext(sid);
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
    this.releasePrefetch();
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
