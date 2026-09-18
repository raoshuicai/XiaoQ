/**
 * ChatStreamEngine 单元测试
 *
 * 为什么需要它（方案 V2 §5 S3 验收项 ②）：
 *   engine 里的三个计时器（20s 停滞 / 5s×12 重试 / 30s 兜底）互相关联，
 *   手动测试**无法覆盖**这些场景：
 *     - "重试跑满 12 次"要等 60 秒
 *     - "30s 兜底"依赖精确时序
 *     - "切会话时旧 timer 不得污染新会话"根本没法手测
 *   注入 FakeClock 后，这些逻辑能在毫秒内被验证。
 *
 * 路径说明：测试代码在 entry/src/ohosTest/ets/test/，生产代码在 entry/src/main/ets/core/
 */

import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { ChatStreamEngine, StreamCallbacks } from '../../../main/ets/core/ChatStreamEngine.ets';
import { FakeClock } from './FakeClock.ets';

// ─────────────── 与引擎常量保持一致（用于断言时间点）───────────────
const STALL_TIMEOUT: number = 20000;
const SYNC_RETRY_INTERVAL: number = 5000;
const SYNC_RETRY_MAX: number = 12;
const RESUME_TIMEOUT: number = 30000;
const THINKING_TOKEN: string = '思考中。。';

/** 回调记录器：把引擎回调转成可断言的数据 */
class Recorder {
  starts: number = 0;
  contents: string[] = [];
  completions: string[] = [];
  failures: string[] = [];
  indicators: number = 0;
  replaces: string[] = [];
  syncCalls: string[] = [];

  lastContent(): string {
    return this.contents.length > 0 ? this.contents[this.contents.length - 1] : '';
  }
}

function makeCallbacks(rec: Recorder): StreamCallbacks {
  const cb: StreamCallbacks = new StreamCallbacks();
  cb.onStreamStart = (): void => {
    rec.starts = rec.starts + 1;
  };
  cb.onContentUpdate = (full: string): void => {
    rec.contents.push(full);
  };
  cb.onCompletion = (finalContent: string): void => {
    rec.completions.push(finalContent);
  };
  cb.onFailure = (message: string): void => {
    rec.failures.push(message);
  };
  cb.onIndicator = (): void => {
    rec.indicators = rec.indicators + 1;
  };
  cb.onIndicatorReplace = (content: string): void => {
    rec.replaces.push(content);
  };
  cb.onSyncNeeded = (sessionId: string, lastSeq: number): void => {
    rec.syncCalls.push(sessionId + ':' + lastSeq);
  };
  return cb;
}

/** 一次测试的上下文 */
class Ctx {
  clock: FakeClock = new FakeClock();
  rec: Recorder = new Recorder();
  engine: ChatStreamEngine;

  constructor() {
    this.engine = new ChatStreamEngine(this.clock, makeCallbacks(this.rec));
  }
}

export default function chatStreamEngineTest() {
  describe('ChatStreamEngineTest', () => {
    let ctx: Ctx;

    beforeEach(() => {
      ctx = new Ctx();
    });

    // ───────────────────────── 基础流式 ─────────────────────────

    it('accumulates_tokens_and_completes', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      ctx.engine.handleToken('你', 0, '');
      ctx.engine.handleToken('好', 1, '');
      ctx.engine.handleToken('呀', 2, '');
      expect(ctx.rec.lastContent()).assertEqual('你好呀');
      expect(ctx.rec.starts).assertEqual(1);

      ctx.engine.handleDone();
      expect(ctx.rec.completions.length).assertEqual(1);
      expect(ctx.rec.completions[0]).assertEqual('你好呀');
      expect(ctx.engine.isBusy()).assertFalse();
      expect(ctx.engine.getStreamContent()).assertEqual('');
    });

    it('filters_thinking_placeholder_as_first_token', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      // 首个 token 是上游占位符 → 必须丢弃
      ctx.engine.handleToken(THINKING_TOKEN, 0, '');
      expect(ctx.engine.getStreamContent()).assertEqual('');
      // 后续真实 token 正常累积
      ctx.engine.handleToken('正文', 1, '');
      expect(ctx.engine.getStreamContent()).assertEqual('正文');
    });

    it('done_without_content_still_notifies_completion', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      ctx.engine.handleDone();
      // 即使内容为空也必须回调，页面靠它复位 isStreaming/isLoading
      expect(ctx.rec.completions.length).assertEqual(1);
      expect(ctx.rec.completions[0]).assertEqual('');
      expect(ctx.engine.isBusy()).assertFalse();
    });

    it('error_notifies_failure_and_resets_busy', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      ctx.engine.handleToken('部分内容', 0, '');
      ctx.engine.handleError('连接被重置');
      expect(ctx.rec.failures.length).assertEqual(1);
      expect(ctx.rec.failures[0]).assertEqual('连接被重置');
      expect(ctx.engine.isBusy()).assertFalse();
      expect(ctx.engine.getStreamContent()).assertEqual('');
    });

    // ───────────────────── 断线与占位符 ─────────────────────

    it('indicator_on_disconnect_when_streaming', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      ctx.engine.handleDisconnected();
      expect(ctx.rec.indicators).assertEqual(1);
      expect(ctx.engine.hasPendingIndicator()).assertTrue();
    });

    it('indicator_not_duplicated_on_repeat_disconnect', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      // 模拟服务端停 20 秒、WS 每 2 秒重连失败一次的场景
      ctx.engine.handleDisconnected();
      ctx.engine.handleDisconnected();
      ctx.engine.handleDisconnected();
      expect(ctx.rec.indicators).assertEqual(1);
    });

    it('no_indicator_when_not_streaming', 0, () => {
      ctx.engine.bindSession('s1');
      // 没有 begin()，即当前没有进行中的流
      ctx.engine.handleDisconnected();
      expect(ctx.rec.indicators).assertEqual(0);
      expect(ctx.engine.hasPendingIndicator()).assertFalse();
    });

    it('sync_pending_with_content_replaces_indicator', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      ctx.engine.handleDisconnected();
      ctx.engine.handleSyncPending('补发的完整回复');
      expect(ctx.rec.replaces.length).assertEqual(1);
      expect(ctx.rec.replaces[0]).assertEqual('补发的完整回复');
      expect(ctx.engine.hasPendingIndicator()).assertFalse();
    });

    it('sync_pending_empty_content_keeps_indicator', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      ctx.engine.handleDisconnected();
      // 服务端还没准备好 → 返回空内容，占位符应当保留，等 retry
      ctx.engine.handleSyncPending('');
      expect(ctx.rec.replaces.length).assertEqual(0);
      expect(ctx.engine.hasPendingIndicator()).assertTrue();
    });

    // ───────────────────── 三个计时器 ─────────────────────

    it('stall_timer_fires_after_20s_no_token', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      ctx.clock.advance(STALL_TIMEOUT - 1);
      expect(ctx.rec.syncCalls.length).assertEqual(0);
      ctx.clock.advance(1);
      expect(ctx.rec.syncCalls.length).assertEqual(1);
      expect(ctx.rec.syncCalls[0]).assertEqual('s1:-1');
    });

    it('stall_timer_cleared_by_incoming_token', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      ctx.engine.handleToken('a', 0, '');
      // token 到达后停滞计时器应被清除 → 再推进 20s 也不该触发
      ctx.clock.advance(STALL_TIMEOUT * 2);
      expect(ctx.rec.syncCalls.length).assertEqual(0);
    });

    it('sync_retry_runs_at_most_12_times', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      ctx.engine.handleDisconnected();      // 产生占位符 → pendingIndicator = true
      ctx.rec.syncCalls = [];
      ctx.engine.handleConnected();         // 触发 startSyncRetry
      expect(ctx.rec.syncCalls.length).assertEqual(1);   // onConnect 里立即发一次
      // 推进 12 个重试间隔
      ctx.clock.advance(SYNC_RETRY_INTERVAL * SYNC_RETRY_MAX);
      // 首次 + 12 次重试 = 13；第 13 次重试因超过上限而停止
      const afterMax: number = ctx.rec.syncCalls.length;
      expect(afterMax >= 12).assertTrue();
      // 再推进 10 个间隔，不应再增加（已停止）
      ctx.clock.advance(SYNC_RETRY_INTERVAL * 10);
      expect(ctx.rec.syncCalls.length).assertEqual(afterMax);
    });

    it('sync_retry_stops_once_indicator_replaced', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      // 先喂一个 token 清掉 20s 停滞计时器 —— 否则它会混进后面的断言
      // （这正是 S3 要管住的风险：三个计时器同时活跃时会互相干扰）
      ctx.engine.handleToken('x', 0, '');
      ctx.engine.handleDisconnected();
      ctx.engine.handleConnected();
      ctx.clock.advance(SYNC_RETRY_INTERVAL);            // 跑一轮重试
      const before: number = ctx.rec.syncCalls.length;
      expect(before > 1).assertTrue();                   // 初始 1 次 + 重试 1 次
      // 续流内容到达 → pendingIndicator 变 false
      ctx.engine.handleSyncPending('内容到了');
      // 只推进 2 个间隔：验证"下一轮进来就停"，同时不超过 stall 的 20s
      ctx.clock.advance(SYNC_RETRY_INTERVAL * 2);
      // ⚠️ 下一轮 interval 进来时会先判 !pendingIndicator 成立 → stopSyncRetry + return，
      //    因此**不会**再调 onSyncNeeded。数量必须保持不变。
      expect(ctx.rec.syncCalls.length).assertEqual(before);
    });

    it('resume_timeout_forces_retry_after_30s', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      // 同样先清掉停滞计时器，隔离出 resume timer 单独验证
      ctx.engine.handleToken('x', 0, '');
      ctx.engine.handleSyncResume(5);       // 服务端说流还在跑
      ctx.rec.syncCalls = [];
      ctx.clock.advance(RESUME_TIMEOUT - 1);
      expect(ctx.rec.syncCalls.length).assertEqual(0);
      // 30s 到点 → 触发 startSyncRetry(true)
      ctx.clock.advance(1);
      // ⚠️ 注意：startSyncRetry 用的是 setInterval，首次回调在 5 秒之后，
      //    所以 30s 那一刻本身不会立刻发 sync_pending，必须再推进一个间隔。
      //    （这是实测确认的实现细节：兜底 → 启动重试循环 → 5s 后首次发出）
      expect(ctx.rec.syncCalls.length).assertEqual(0);
      ctx.clock.advance(SYNC_RETRY_INTERVAL);
      expect(ctx.rec.syncCalls.length > 0).assertTrue();
    });

    it('resume_timeout_not_fired_if_done_arrives', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      ctx.engine.handleSyncResume(5);
      ctx.engine.handleToken('x', 0, '');
      ctx.engine.handleDone();              // 流正常结束
      ctx.rec.syncCalls = [];
      ctx.clock.advance(RESUME_TIMEOUT * 3);
      expect(ctx.rec.syncCalls.length).assertEqual(0);
    });

    // ───────────────────── 跨会话隔离 ─────────────────────

    it('drops_token_from_other_session', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      ctx.engine.handleToken('本会话', 0, 's1');
      ctx.engine.handleToken('别的会话的补发', 1, 's2');   // 应被丢弃
      expect(ctx.engine.getStreamContent()).assertEqual('本会话');
    });

    it('accepts_token_when_msg_session_is_empty', 0, () => {
      // 服务端当前不下发 session_id → 传空串时必须跳过校验（行为兼容）
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      ctx.engine.handleToken('abc', 0, '');
      expect(ctx.engine.getStreamContent()).assertEqual('abc');
    });

    // ───────────────────── 生命周期 ─────────────────────

    it('begin_clears_previous_stream_content', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      ctx.engine.handleToken('旧内容', 0, '');
      ctx.engine.begin();                    // 用户又发了一条
      expect(ctx.engine.getStreamContent()).assertEqual('');
    });

    it('bind_session_resets_state_and_timers', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      ctx.engine.handleToken('s1 的内容', 0, '');
      ctx.engine.handleDisconnected();
      expect(ctx.engine.hasPendingIndicator()).assertTrue();

      ctx.engine.bindSession('s2');          // 切会话
      expect(ctx.engine.getSessionId()).assertEqual('s2');
      expect(ctx.engine.getStreamContent()).assertEqual('');
      expect(ctx.engine.isBusy()).assertFalse();
      expect(ctx.engine.hasPendingIndicator()).assertFalse();
      expect(ctx.clock.pendingCount()).assertEqual(0);   // 计时器全部清掉
    });

    it('dispose_clears_all_timers', 0, () => {
      ctx.engine.bindSession('s1');
      ctx.engine.begin();
      ctx.engine.handleDisconnected();
      ctx.engine.handleConnected();
      expect(ctx.clock.pendingCount() > 0).assertTrue();
      ctx.engine.dispose();
      expect(ctx.clock.pendingCount()).assertEqual(0);
      expect(ctx.engine.isBusy()).assertFalse();
    });
  });
}
