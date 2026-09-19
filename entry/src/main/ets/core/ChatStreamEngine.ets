/**
 * ChatStreamEngine —— 流式聊天状态机
 *
 * S3 引入。把原先散在 ChatPage 的 8 个事件处理方法里的**状态与计时器**
 * 集中到这里，页面只负责渲染。这样做的价值：
 *   1. 三个计时器互相 cancel 的顺序只在一处出现，不再散落
 *   2. 注入 Clock 之后可以用 FakeClock 跑真单测（见 Timers.ets 说明）
 *   3. 后续 S12 多会话时，sessionId 校验有唯一落点
 *
 * ⚠️ 搬迁原则（方案 V2 §5 S3）：**逐行抄，不要顺手优化，常量数值一字不改**。
 *    原逻辑出自 ChatPage v2.0.10 的 onChatTokenMsg / onChatDoneMsg /
 *    onChatErrorMsg / onSyncResumeMsg / onSyncPendingMsg / onWsConnected /
 *    onWsDisconnected 七个方法。
 *
 * 分层约束：本文件属于 core/，不得 import 任何 ArkUI 或业务模块 ——
 * 页面的 messageList / @State 通过 StreamCallbacks 回调驱动。
 */

import { Clock, NO_TIMER } from './Timers.ets';

// ── 时间常量：数值长期调优得出，搬迁时一字不改 ──
const STALL_TIMEOUT: number = 20000;      // 流式停滞 20s → 主动请求续流
/**
 * 新会话首条消息的停滞窗口。
 *
 * ⚠️ 为什么要单独给一个更长的值（实测数据）：
 *   新 session 的 prompt cache 是冷的。system prompt 52KB、首轮输入约 2.7 万 token，
 *   实测首个 token 要 **45-60 秒**才到（对比老会话命中上千万 cache token，秒级返回）。
 *   用默认 20s 会在 token 到达前就触发 sync_pending，界面上表现为「一直恢复中」甚至
 *   被当成发送失败。这不是网络问题，是首次冷启动的固有成本。
 */
const NEW_SESSION_STALL_TIMEOUT: number = 90000;
export const STALL_TIMEOUT_DEFAULT: number = STALL_TIMEOUT;
export const STALL_TIMEOUT_NEW_SESSION: number = NEW_SESSION_STALL_TIMEOUT;
const SYNC_RETRY_INTERVAL: number = 5000; // sync_pending 重试间隔
const SYNC_RETRY_MAX: number = 12;        // 重试上限（12 × 5s = 60s）
const RESUME_TIMEOUT: number = 30000;     // 续流恢复后等 chat_done 的兜底
const THINKING_TOKEN: string = '思考中。。'; // 上游占位符，不得泄漏进正文

/**
 * 页面侧回调集合。
 *
 * ⚠️ ArkTS 限制（实测踩坑）：必须用 **class**，不能用 interface + 对象字面量
 *    —— 否则编译报 `arkts-no-untyped-obj-literals` / 10605038。
 *    页面用法：`const cb = new StreamCallbacks(); cb.onFailure = ...;`
 *    未赋值的回调有安全的空实现，不会崩。
 */
export class StreamCallbacks {
  onStreamStart: () => void = (): void => {};

  onContentUpdate: (fullContent: string) => void = (fullContent: string): void => {};

  onCompletion: (finalContent: string) => void = (finalContent: string): void => {};

  onFailure: (message: string) => void = (message: string): void => {};

  onIndicator: () => void = (): void => {};

  onIndicatorReplace: (content: string) => void = (content: string): void => {};

  onSyncNeeded: (sessionId: string, lastSeq: number) => void =
    (sessionId: string, lastSeq: number): void => {};
}

export class ChatStreamEngine {
  private clock: Clock;
  private cb: StreamCallbacks;

  private sessionId: string = '';
  private lastSeq: number = -1;
  private streamContent: string = '';
  private isStreaming: boolean = false;
  /** 页面上是否存在未被替换的占位符（取代原先靠遍历 messageList 的 hasIndicator）*/
  private pendingIndicator: boolean = false;

  private stallTimer: number = NO_TIMER;
  private syncRetryTimer: number = NO_TIMER;
  private syncRetryCount: number = 0;
  private resumeTimer: number = NO_TIMER;

  constructor(clock: Clock, cb: StreamCallbacks) {
    this.clock = clock;
    this.cb = cb;
  }

  // ──────────────────────────── 会话绑定 ────────────────────────────

  /**
   * 绑定当前会话。切换会话时内部先 reset()（清掉所有计时器），
   * 避免旧会话的计时器回调把内容/报错注入新会话
   * （MoA-2 #02 指出的跨会话污染）。
   */
  public bindSession(id: string): void {
    if (this.sessionId === id) {
      return;
    }
    this.reset();
    this.sessionId = id;
  }

  public getSessionId(): string {
    return this.sessionId;
  }

  // ──────────────────────────── 页面调用 ────────────────────────────

  /**
   * 用户发出新消息前调用：重置累积内容并启动停滞计时器。
   *
   * @param stallTimeoutMs 停滞判定窗口，默认 20s。
   *   新会话的首条消息**必须传更大的值**（见 STALL_TIMEOUT_NEW_SESSION 的注释）：
   *   新 session 冷缓存，首个 token 实测要 45-60 秒。
   */
  public begin(stallTimeoutMs: number = STALL_TIMEOUT): void {
    this.isStreaming = true;
    this.streamContent = '';
    this.clearStallTimer();
    // 流式回复停顿时长超过窗口仍无 token 则主动请求 sync_pending
    this.stallTimer = this.clock.setTimeout((): void => {
      this.stallTimer = NO_TIMER;
      if (this.isStreaming) {
        console.info('streamStallTimer: no tokens for ' + (stallTimeoutMs / 1000)
          + 's, requesting sync_pending');
        this.cb.onSyncNeeded(this.sessionId, this.lastSeq);
      }
    }, stallTimeoutMs);
    this.cb.onStreamStart();
  }

  public getStreamContent(): string {
    return this.streamContent;
  }

  public isBusy(): boolean {
    return this.isStreaming;
  }

  public hasPendingIndicator(): boolean {
    return this.pendingIndicator;
  }

  // ──────────────────────────── WS 事件入口 ────────────────────────────

  /**
   * chat_token 到达。
   * @param msgSessionId 消息携带的会话 id（服务端当前不下发，传空串时跳过校验）
   */
  public handleToken(content: string, seq: number | undefined, msgSessionId: string): void {
    // 跨会话 token 丢弃：切会话后旧会话的补发 token 不得混进当前会话
    // （方案 V2 §3 决策 1）
    if (msgSessionId !== '' && msgSessionId !== this.sessionId) {
      return;
    }
    // 记录最后收到的 seq（支持断点续流）
    if (seq !== undefined) {
      this.lastSeq = seq;
    }
    // 收到第一个 token 即停止 sync 重试（避免 retry 再发一次 sync 导致重复回复）
    if (this.pendingIndicator) {
      this.stopSyncRetry();
    }
    // 收到 token 即清除停滞超时（流正常进行）
    this.clearStallTimer();
    // 过滤"思考中。。"占位符，防止泄漏到最终答复
    if (this.streamContent.length === 0
      && (content === THINKING_TOKEN || content.startsWith(THINKING_TOKEN))) {
      return;
    }
    this.streamContent += content;
    this.cb.onContentUpdate(this.streamContent);
  }

  /**
   * chat_done：流结束。
   * ⚠️ 无论内容是否为空都回调 onCompletion —— 页面需要它复位
   * isStreaming / isLoading（原实现在 streamContent 为空时同样要复位这些 UI 状态）。
   * 是否落库交由页面按内容长度自行判断。
   */
  public handleDone(): void {
    const finalContent: string = this.streamContent;
    this.streamContent = '';
    this.isStreaming = false;
    this.lastSeq = -1;
    this.stopSyncRetry();
    this.clearStallTimer();
    this.clearResumeTimer();
    this.cb.onCompletion(finalContent);
  }

  /** chat_error：流失败 */
  public handleError(message: string): void {
    this.isStreaming = false;
    this.clearStallTimer();
    this.clearResumeTimer();
    this.cb.onFailure(message);
    this.streamContent = '';
  }

  /** sync_resume：服务端通知流已恢复，后续 token 会实时推送 */
  public handleSyncResume(caughtUp: number): void {
    console.info('sync_resume: stream resumed, caught_up=' + caughtUp);
    // 如果有已累积的 streamContent，替换掉恢复提示
    if (this.streamContent.length > 0) {
      this.cb.onIndicatorReplace(this.streamContent);
      this.pendingIndicator = false;
    }
    this.isStreaming = true; // 让流式气泡显示
    // 方案D：设 30 秒超时守卫生，超时后未收到 chat_done 则重启 retry 轮询
    this.clearResumeTimer();
    this.resumeTimer = this.clock.setTimeout((): void => {
      if (this.isStreaming) {
        console.info('streamResumeTimeout: no chat_done after 30s, starting forced retry');
        this.startSyncRetry(true);
      }
      this.resumeTimer = NO_TIMER;
    }, RESUME_TIMEOUT);
  }

  /** sync_pending_response：服务端补发了离线缓存内容 */
  public handleSyncPending(content: string): void {
    if (content.length > 0) {
      this.cb.onIndicatorReplace(content);
      this.pendingIndicator = false;
    }
    // 内容为空 → 服务器还没准备好，retry timer 会继续重试
  }

  /** WS 连上：若存在未恢复的流，主动请求续流 */
  public handleConnected(): void {
    console.info('WS connected');
    // 只对"流中断未恢复"的会话发送同步请求（避免已完成流重复回放）
    if (this.pendingIndicator) {
      this.cb.onSyncNeeded(this.sessionId, this.lastSeq);
      this.startSyncRetry();
    }
  }

  /** WS 断开：流式进行中则标记需要占位符（已有则不重复插）*/
  public handleDisconnected(): void {
    console.info('WS disconnected');
    if (this.isStreaming && !this.pendingIndicator) {
      this.pendingIndicator = true;
      this.cb.onIndicator();
    }
  }

  // ──────────────────────────── 生命周期 ────────────────────────────

  /** 重置全部状态与计时器（切会话 / 页面销毁时调用）*/
  public reset(): void {
    this.stopSyncRetry();
    this.clearStallTimer();
    this.clearResumeTimer();
    this.streamContent = '';
    this.isStreaming = false;
    this.pendingIndicator = false;
    this.lastSeq = -1;
  }

  public dispose(): void {
    this.reset();
  }

  // ──────────────────────────── 计时器（内部）────────────────────────────

  // sync_pending 重试循环（服务器可能还在处理中）
  // force: 方案D超时兜底，跳过 pendingIndicator 检查
  private startSyncRetry(force: boolean = false): void {
    this.stopSyncRetry();
    this.syncRetryCount = 0;
    this.syncRetryTimer = this.clock.setInterval((): void => {
      this.syncRetryCount++;
      // 每 5 秒重试一次，最多 60 秒
      if (this.syncRetryCount > SYNC_RETRY_MAX || (!force && !this.pendingIndicator)) {
        this.stopSyncRetry();
        return;
      }
      this.cb.onSyncNeeded(this.sessionId, this.lastSeq);
    }, SYNC_RETRY_INTERVAL);
  }

  private stopSyncRetry(): void {
    if (this.syncRetryTimer !== NO_TIMER) {
      this.clock.clearInterval(this.syncRetryTimer);
      this.syncRetryTimer = NO_TIMER;
    }
  }

  private clearStallTimer(): void {
    if (this.stallTimer !== NO_TIMER) {
      this.clock.clearTimeout(this.stallTimer);
      this.stallTimer = NO_TIMER;
    }
  }

  private clearResumeTimer(): void {
    if (this.resumeTimer !== NO_TIMER) {
      this.clock.clearTimeout(this.resumeTimer);
      this.resumeTimer = NO_TIMER;
    }
  }
}
