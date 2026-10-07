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
import { MsgMetrics } from '../models/ChatModels.ets';

// ── 时间常量：数值长期调优得出，搬迁时一字不改 ──
const STALL_TIMEOUT: number = 20000;      // 流式停滞 20s → 主动请求续流
/**
 * 有活跃工具时用的停滞阈值（10 分钟）。
 *
 * 单次工具执行（编译 / 抓取 / 长 sleep）耗时可能远超 20s，且期间**没有任何
 * 事件到达**，用 20s 判停滞必然误判 —— 实测 sleep 65 就会触发
 * `streamStallTimer: no tokens for 20s`（见 notifyActivity 注释）。
 * 语义上「工具在跑」= 「流是活的」。极端情况（工具永不返回）由服务端
 * 120s 空闲超时兜底，不会真正挂死。
 */
const TOOL_ACTIVE_STALL_TIMEOUT: number = 600000;
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

  /**
   * S41：流结束。第二个参数是本轮性能指标（老服务端不带 → undefined）。
   * ⚠️ 用可选参数而不是新回调，避免动调用方契约。
   */
  onCompletion: (finalContent: string, metrics?: MsgMetrics) => void =
    (finalContent: string, metrics?: MsgMetrics): void => {};

  onFailure: (message: string) => void = (message: string): void => {};

  /**
   * 服务端确认「该会话已无活跃流、也没有离线缓存」。
   * 页面据此清掉「恢复中」占位符并复位加载态 —— 否则流状态会永远挂着。
   */
  onStreamMissing: () => void = (): void => {};

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
  /** begin 时传入的停滞判定窗口；notifyActivity 重装计时器时复用 */
  private stallTimeoutMs: number = STALL_TIMEOUT;
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
    this.stallTimeoutMs = stallTimeoutMs;
    this.armStallTimer();
    this.cb.onStreamStart();
  }

  /**
   * 安装（或重装）停滞计时器。begin 与 notifyActivity 共用。
   *
   * 语义：距离**上次有任何活动**超过 stallTimeoutMs 仍无 token → 请求 sync_pending。
   */
  private armStallTimer(): void {
    this.clearStallTimer();
    const ms: number = this.stallTimeoutMs;
    // 流式回复停顿时长超过窗口仍无 token 则主动请求 sync_pending
    this.stallTimer = this.clock.setTimeout((): void => {
      this.stallTimer = NO_TIMER;
      if (this.isStreaming) {
        console.info('streamStallTimer: no tokens for ' + (ms / 1000)
          + 's, requesting sync_pending');
        this.cb.onSyncNeeded(this.sessionId, this.lastSeq);
      }
    }, ms);
  }

  /**
   * 工具进度信号到达时调用 —— 重装停滞计时器。
   *
   * ⚠️ 两个层次的问题，只做第一个不够（实测验证过）：
   *   ① chat_progress 走 WsBridgeHooks.onProgress **绕过 engine**，
   *      不会像 chat_token 那样重置 stallTimer；
   *   ② **更关键**：单次工具执行的耗时（如 sleep 65）**本身就可能超过
   *      停滞阈值**，期间不会有任何事件到达 —— 所以"事件到达时重置"仍然会误判。
   *      实测：21:33:5x 收到 running 并重置，21:34:10 照样触发
   *      `streamStallTimer: no tokens for 20s`。
   *
   * 因此：**有活跃工具时改用大幅延长的阈值** ——
   *   语义上"工具在跑"就等价于"流是活的"，不该按 token 间隔判停滞。
   *   极端情况（工具永不返回）仍有服务端 120s 空闲超时兜底。
   *
   * @param hasActiveTool 当前是否仍有未完成的工具（由页面根据 toolProgress 判定）
   */
  public notifyActivity(hasActiveTool: boolean): void {
    if (!this.isStreaming) {
      return;
    }
    this.stallTimeoutMs = hasActiveTool ? TOOL_ACTIVE_STALL_TIMEOUT : STALL_TIMEOUT;
    this.armStallTimer();
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
    // 收到 token = 流确实在推进 —— 补齐 isStreaming 的恢复路径。
    //   ⚠️ cb.onStreamStart() 全项目只在 begin()（用户发新消息）里调用一次，
    //   而切会话会把 ChatPage 的 isStreaming 置 false 且**没有任何恢复路径** ——
    //   结果切走再切回时，进度条和流式气泡都消失（评审 REV-01 的一部分）。
    //   这里让"收到 token"本身就能把 UI 状态拉回来。
    if (!this.isStreaming) {
      this.isStreaming = true;
      this.cb.onStreamStart();
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
  public handleDone(metrics?: MsgMetrics, msgSessionId: string = ''): void {
    // V4-A4：跨会话归属校验（与 handleToken 同模式，空串跳过兼容旧服务端）
    if (msgSessionId !== '' && msgSessionId !== this.sessionId) {
      console.warn('drop cross-session handleDone: ' + msgSessionId + ' (current ' + this.sessionId + ')');
      return;
    }
    const finalContent: string = this.streamContent;
    this.streamContent = '';
    this.isStreaming = false;
    this.lastSeq = -1;
    this.stopSyncRetry();
    this.clearStallTimer();
    this.clearResumeTimer();
    this.cb.onCompletion(finalContent, metrics);
  }

  /** chat_error：流失败 */
  public handleError(message: string, msgSessionId: string = ''): void {
    // V4-A4：跨会话归属校验
    if (msgSessionId !== '' && msgSessionId !== this.sessionId) {
      console.warn('drop cross-session handleError: ' + msgSessionId + ' (current ' + this.sessionId + ')');
      return;
    }
    this.isStreaming = false;
    this.clearStallTimer();
    this.clearResumeTimer();
    this.cb.onFailure(message);
    this.streamContent = '';
  }

  /** sync_resume：服务端通知流已恢复，后续 token 会实时推送 */
  public handleSyncResume(caughtUp: number, msgSessionId: string = ''): void {
    // V4-A4：跨会话归属校验
    if (msgSessionId !== '' && msgSessionId !== this.sessionId) {
      console.warn('drop cross-session handleSyncResume: ' + msgSessionId + ' (current ' + this.sessionId + ')');
      return;
    }
    console.info('sync_resume: stream resumed, caught_up=' + caughtUp);
    // 如果有已累积的 streamContent，替换掉恢复提示
    if (this.streamContent.length > 0) {
      this.cb.onIndicatorReplace(this.streamContent);
      this.pendingIndicator = false;
    }
    this.isStreaming = true; // 让流式气泡显示
    // 评审 REV-07 附带：同步通知页面，避免「engine 认为在流式、页面认为不在」的状态不一致。
    //   （同类问题在 handleToken 也补过一次 —— 那条覆盖"收到 token"的路径，这条覆盖"仅有
    //     stream_resume 通知、还没收到 token"的窗口。）
    this.cb.onStreamStart();
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
  public handleSyncPending(content: string, streamMissing: boolean = false, msgSessionId: string = ''): void {
    // V4-A4：跨会话归属校验
    if (msgSessionId !== '' && msgSessionId !== this.sessionId) {
      console.warn('drop cross-session handleSyncPending: ' + msgSessionId + ' (current ' + this.sessionId + ')');
      return;
    }
    if (content.length > 0) {
      this.cb.onIndicatorReplace(content);
      this.pendingIndicator = false;
      return;
    }
    // 内容为空有两种可能，此前无法区分，导致会话永久卡在「恢复中」：
    //   ① 流已注册但还没有 token（刚起步）→ 继续等，retry timer 会再试
    //   ② 该会话已无活跃流、也无离线缓存 → 服务端带 stream_missing=true，必须结束等待
    if (streamMissing) {
      console.info('sync_pending: server reports no active stream -> ending wait');
      this.stopSyncRetry();
      this.clearStallTimer();
      this.clearResumeTimer();
      this.isStreaming = false;
      this.pendingIndicator = false;
      this.streamContent = '';
      this.lastSeq = -1;
      this.cb.onStreamMissing();
    }
  }

  /**
   * 外部告知：消息列表里残留着「恢复中」占位符（APP 重启/被杀后遗留）。
   *
   * ⚠️ 为什么需要这个入口：`pendingIndicator` 是内存态，重启就丢了，
   *    而占位符是持久化在消息列表里的 —— 只靠内存标志无法发现这种残留。
   *    标上之后，WS 一连上 `handleConnected()` 就会去问服务端：
   *    有流则补发内容，没流则回 stream_missing → 页面把占位符删掉。
   */
  public noteStaleIndicator(): void {
    if (!this.isStreaming) {
      this.pendingIndicator = true;
      console.info('stale indicator detected in message list; will probe server on connect');
    }
  }

  /** WS 连上：若存在未恢复的流，主动请求续流 */
  public handleConnected(): void {
    console.info('WS connected');
    // V4-A10：条件放宽为 pendingIndicator || isStreaming（防御性冗余）。
    //   on('close') 路径已能置位 pendingIndicator，放宽防某些平台 close 事件延迟；
    //   isStreaming 时重连也要补 sync（可能漏了中间 token）。
    if (this.pendingIndicator || this.isStreaming) {
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
