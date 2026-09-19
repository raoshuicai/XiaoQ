/**
 * ApproveService —— 全局审批中心
 *
 * S7 引入（全局队列 + 去重 + 活跃页判定 + 提交），S11 增强：
 *   - 携带触发上下文（description / sessionId / 收到时间）
 *   - 维护审批历史（最多 20 条，持久化到 Preferences）
 *
 * 解决的问题（MoA-2 #08 / 风险清单 #11）：
 *   原先审批状态全部长在 ChatPage 上 —— 意味着**用户不在聊天页时，
 *   审批到达就没人接收**，只能等超时。而审批是 Gateway 侧阻塞等待的，
 *   超时等于任务失败。
 *
 * ⚠️ 本类刻意不做成 @Observed：订阅者用回调 + 各自 @State 承接，
 *    比 @Observed 深层观测更可控（ArkUI 对非组件类的观测有诸多限制）。
 */

import { rest } from '../core/HermesRest.ets';
import { apiConfig } from '../core/ApiConfig.ets';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** 一次审批请求 */
export class ApproveRequest {
  runId: string = '';
  command: string = '';
  patterns: string[] = [];
  /** Gateway 给的触发说明（S11） */
  description: string = '';
  /** 哪个会话触发的（S11） */
  sessionId: string = '';
  /** 收到时间（毫秒，S11） */
  receivedAt: number = 0;
  /** 用户的选择：once/session/always/deny；空 = 未处理（S11，历史用） */
  choice: string = '';
  /** 处理时间（毫秒，S11，历史用） */
  handledAt: number = 0;
}

/**
 * S42：服务端未处理审批（GET /api/approvals/pending 的 items 元素）。
 * 字段名与 xiaoq-api 保持一致（snake_case）。
 */
export interface ServerPendingItem {
  run_id: string;
  command: string;
  description: string;
  pattern_keys: string[];
  session_id: string;
  created_at: number;
  age_s: number;
  expired: boolean;
}

export interface ServerPendingResp {
  items: ServerPendingItem[];
  count: number;
}

/** 历史最多保留条数 */
const HISTORY_MAX: number = 20;
const PREF_STORE: string = 'xiaoq_approve';
const PREF_KEY: string = 'approve_history';

export class ApproveService {
  /** 待处理队列（current 之外的） */
  private queue: ApproveRequest[] = [];
  /** 当前展示中的请求 */
  private current: ApproveRequest | null = null;
  /** 提交中 */
  private inProgress: boolean = false;
  /** 已处理过的 run_id（防重连重放复活） */
  private handled: string[] = [];

  /**
   * 最近一次 respond() 失败的**具体原因**，供页面展示。
   * ⚠️ 不要让页面用固定文案兜底：此前 404（授权对应的 run 已不存在，如测试残留卡片）
   *    被显示成「请检查 API 密钥与网络」，把用户引向完全错误的方向。
   */
  public lastError: string = '';
  /** 当前前台页面名（只有它的卡片会渲染） */
  private activePage: string = '';
  /** 变更订阅者 */
  private listeners: Array<() => void> = [];
  /** 审批历史（最新在前，最多 HISTORY_MAX 条） */
  private history: ApproveRequest[] = [];
  private prefStore: preferences.Preferences | null = null;

  /**
   * 绑定 Context 并加载历史。
   * 由 ChatPage（或任何先启动的页面）在 aboutToAppear 里调用一次即可，重复调用无害。
   */
  public async bind(ctx: common.Context): Promise<void> {
    if (this.prefStore !== null) {
      return;
    }
    try {
      this.prefStore = await preferences.getPreferences(ctx, PREF_STORE);
      const raw: string = await this.prefStore.get(PREF_KEY, '') as string;
      if (raw.length > 0) {
        this.history = JSON.parse(raw) as ApproveRequest[];
      }
      this.notify();
    } catch (e) {
      console.error('approve history load failed: ' + e);
    }
  }

  private async persist(): Promise<void> {
    if (this.prefStore === null) {
      return;
    }
    try {
      await this.prefStore.put(PREF_KEY, JSON.stringify(this.history));
      await this.prefStore.flush();
    } catch (e) {
      console.error('approve history save failed: ' + e);
    }
  }

  /** 审批历史（最新在前） */
  public getHistory(): ApproveRequest[] {
    return this.history;
  }

  /** 清空历史 */
  public async clearHistory(): Promise<void> {
    this.history = [];
    await this.persist();
    this.notify();
  }

  /**
   * 把一条记录写入历史。
   * @param isHandled true=已处理（记 handledAt）；false=待处理（handledAt 留 0，
   *        这样「审批历史」能把它识别出来并允许重新打开）
   */
  private async record(req: ApproveRequest, choice: string, isHandled: boolean): Promise<void> {
    const entry: ApproveRequest = new ApproveRequest();
    entry.runId = req.runId;
    entry.command = req.command;
    entry.patterns = req.patterns;
    entry.description = req.description;
    entry.sessionId = req.sessionId;
    entry.receivedAt = req.receivedAt;
    entry.choice = choice;
    entry.handledAt = isHandled ? Date.now() : 0;

    const out: ApproveRequest[] = [entry];
    for (const h of this.history) {
      // 同一个 run+command 只留最新一条
      if (!(h.runId === entry.runId && h.command === entry.command)) {
        out.push(h);
      }
      if (out.length >= HISTORY_MAX && isHandled) {
        break;
      }
    }
    this.history = out;
    this.trimHistory();
    await this.persist();
  }

  /**
   * S42：裁剪历史，但**待处理的条目优先保留**。
   * 理由：待处理是"活的"（用户还能继续审批），历史记录是"死的"（仅供回顾），
   * 不该因为回顾记录多就把还能操作的挤掉。
   */
  private trimHistory(): void {
    if (this.history.length <= HISTORY_MAX) {
      return;
    }
    const pending: ApproveRequest[] = [];
    const reviewed: ApproveRequest[] = [];
    for (const h of this.history) {
      if (h.choice === 'postponed') {
        pending.push(h);
      } else {
        reviewed.push(h);
      }
    }
    const out: ApproveRequest[] = [];
    for (const h of pending) {
      if (out.length >= HISTORY_MAX) {
        break;
      }
      out.push(h);
    }
    for (const h of reviewed) {
      if (out.length >= HISTORY_MAX) {
        break;
      }
      out.push(h);
    }
    this.history = out;
  }

  /**
   * 入队（WS 收到 approve_request 时调用）。
   *
   * ⚠️ 去重键 = `runId | command`，**不能只用 runId**：
   *   同一轮对话（同一个 run）里可能触发**多次**审批（例如连续两个危险命令），
   *   而 run_id 是相同的。若按 run_id 去重，第二次会被误判成"WS 重连重放"而丢弃
   *   —— 实测表现就是「APP 只弹了第一个卡片，第二个永远不出现」，
   *   服务端则在等第二个审批直到超时。
   *   带上 command 后：重连重放（runId+command 都相同）仍能正确去重，
   *   同 run 的不同命令则各自成卡片。
   */
  private dedupKey(runId: string, command: string): string {
    return runId + '|' + command;
  }

  public push(runId: string, command: string, patterns: string[],
              description: string, sessionId: string): void {
    if (runId.length === 0) {
      return;
    }
    const key: string = this.dedupKey(runId, command);
    // 已处理过 → 忽略（WS 重连重放）
    if (this.handled.indexOf(key) >= 0) {
      return;
    }
    // 已在队列或正展示 → 忽略
    if (this.current !== null && this.dedupKey(this.current.runId, this.current.command) === key) {
      return;
    }
    for (const q of this.queue) {
      if (this.dedupKey(q.runId, q.command) === key) {
        return;
      }
    }

    const req: ApproveRequest = new ApproveRequest();
    req.runId = runId;
    req.command = command;
    req.patterns = patterns;
    req.description = description;
    req.sessionId = sessionId;
    req.receivedAt = Date.now();

    this.queue.push(req);
    this.promoteIfIdle();
    this.notify();
  }

  /** 队列空且没有展示中的 → 把队首提上来 */
  private promoteIfIdle(): void {
    if (this.current === null && this.queue.length > 0) {
      this.current = this.queue.shift() as ApproveRequest;
      this.inProgress = false;
    }
  }

  /** 当前是否应该展示卡片（前台页面才有权渲染） */
  public shouldRender(pageName: string): boolean {
    return this.current !== null && this.activePage === pageName;
  }

  public getCurrent(): ApproveRequest | null {
    return this.current;
  }

  public isInProgress(): boolean {
    return this.inProgress;
  }

  /** 待处理总数（当前 + 排队），用于角标 */
  public getPendingCount(): number {
    return this.queue.length + (this.current !== null ? 1 : 0);
  }

  /** 页面登记自己成为前台（onPageShow） */
  public setActivePage(pageName: string): void {
    this.activePage = pageName;
    this.notify();
  }

  /** 页面退出前台（onPageHide） */
  public clearActivePage(pageName: string): void {
    if (this.activePage === pageName) {
      this.activePage = '';
      this.notify();
    }
  }

  /**
   * 提交用户选择。
   * choice: once / session / always / deny
   * 返回是否提交成功（供 UI 决定提示语）。
   */
  public async respond(choice: string): Promise<boolean> {
    const req: ApproveRequest | null = this.current;
    if (req === null || this.inProgress) {
      return false;
    }

    // 反馈 3：提交前必须先校验配置 —— 否则用户点了才失败，提示也没指导意义
    if (apiConfig.getApiKey().length === 0) {
      return false;
    }

    this.inProgress = true;
    this.notify();

    try {
      // ArkTS：对象字面量必须对应显式声明的类型，不能直接内联
      const body: Record<string, string> = { 'approval': choice };
      await rest.postOnce('/v1/runs/' + encodeURIComponent(req.runId) + '/approval', body);
      this.handled.push(this.dedupKey(req.runId, req.command));
      this.current = null;
      this.inProgress = false;
      this.promoteIfIdle();
      await this.record(req, choice, true);   // S11：记入历史（已处理）
      this.notify();
      return true;
    } catch (e) {
      // 提交失败：保留卡片让用户重试（不清队列、不登记 handled）
      //
      // ⚠️ 这里必须把**具体原因**带出去。此前页面只显示一句
      //    「请检查 API 密钥与网络」，而真实情况往往是 404（服务端没有这个 run，
      //    例如测试残留卡片）—— 文案把用户引向错误的方向。
      const err = e as Error;
      this.lastError = (err !== undefined && err.message !== undefined && err.message.length > 0)
        ? err.message
        : '未知错误';
      this.inProgress = false;
      this.notify();
      return false;
    }
  }

  /**
   * S42：收起卡片，但**不放弃**这条审批。
   *
   * ⚠️ 这是本文件最重要的一处修复。原先的 `dismissCurrent()` 会把
   *    `runId|command` 写进 `handled` 黑名单，而 `push()` 的第一道闸就是
   *    `if (this.handled.indexOf(key) >= 0) return;` ——
   *    后果是：误触一次，服务端重放救不回来，本地也无法恢复，
   *    而服务端 `_pending_approvals` 还在等 5 分钟 → 用户看到的就是"APP 一直卡着"。
   *
   * 现在改为：
   *   · 不进 handled 黑名单（所以随时能恢复）
   *   · 记入历史，choice='postponed' 且 handledAt=0（「审批历史」页据此显示"待处理"并允许点开继续审批）
   *   · 单次调用的去重仍由 push() 的 current/queue 检查负责，不受影响
   */
  public async postponeCurrent(): Promise<void> {
    const req: ApproveRequest | null = this.current;
    if (req === null) {
      return;
    }
    this.current = null;
    this.inProgress = false;
    this.promoteIfIdle();
    await this.record(req, 'postponed', false);
    this.notify();
  }

  /** S42：未处理的审批（「审批历史」页的"待处理"区） */
  public getPostponed(): ApproveRequest[] {
    const out: ApproveRequest[] = [];
    for (const h of this.history) {
      if (h.choice === 'postponed') {
        out.push(h);
      }
    }
    return out;
  }

  /**
   * S42：从审批历史里重新打开一条待处理的审批 —— 让用户"点开继续执行审批动作"。
   * 返回是否成功（找不到该记录时 false）。
   */
  public reopen(runId: string): boolean {
    let idx: number = -1;
    for (let i = 0; i < this.history.length; i++) {
      const h: ApproveRequest = this.history[i];
      if (h.runId === runId && h.choice === 'postponed') {
        idx = i;
        break;
      }
    }
    if (idx < 0) {
      return false;
    }
    const entry: ApproveRequest = this.history[idx];

    // 从历史摘掉（它马上回到展示位）
    const kept: ApproveRequest[] = [];
    for (let i = 0; i < this.history.length; i++) {
      if (i !== idx) {
        kept.push(this.history[i]);
      }
    }
    this.history = kept;

    // 兜底清黑名单：万一这条曾被旧版 dismissCurrent 拉黑过
    const key: string = this.dedupKey(entry.runId, entry.command);
    const hi: number = this.handled.indexOf(key);
    if (hi >= 0) {
      this.handled.splice(hi, 1);
    }

    // 重建请求（保留原始收到时间，便于卡片显示"什么时候来的"）
    const req: ApproveRequest = new ApproveRequest();
    req.runId = entry.runId;
    req.command = entry.command;
    req.patterns = entry.patterns;
    req.description = entry.description;
    req.sessionId = entry.sessionId;
    req.receivedAt = entry.receivedAt;

    this.queue.unshift(req);
    this.promoteIfIdle();
    this.persist();
    this.notify();
    return true;
  }

  /**
   * S42：从服务端补齐未处理的审批（启动 / 回到前台时各拉一次）。
   *
   * ⚠️ 只写进「审批历史」的待处理区，**不自动弹卡片**：
   *    用户刚主动收起过的卡片，重连时又弹出来是骚扰。
   *    这里保证的是"在 设置-审批历史 里能找到"，弹不弹由用户点开决定。
   *
   * @returns 新增的条数（0 表示没有需要补的）
   */
  public async syncFromServer(): Promise<number> {
    try {
      const raw: Object = await rest.get('/api/approvals/pending');
      const resp: ServerPendingResp = raw as ServerPendingResp;
      const list: ServerPendingItem[] = resp.items;
      if (list === undefined || list === null) {
        return 0;
      }
      let added: number = 0;
      for (const it of list) {
        const key: string = this.dedupKey(it.run_id, it.command);
        // 正在展示 / 已在队列 → 跳过
        if (this.current !== null
            && this.dedupKey(this.current.runId, this.current.command) === key) {
          continue;
        }
        let busy: boolean = false;
        for (const q of this.queue) {
          if (this.dedupKey(q.runId, q.command) === key) {
            busy = true;
            break;
          }
        }
        if (busy) {
          continue;
        }
        // 已明确处理过（用户选了选项）→ 不复活
        if (this.handled.indexOf(key) >= 0) {
          continue;
        }
        // 已经在待处理列表里 → 不重复写
        let exists: boolean = false;
        for (const h of this.history) {
          if (h.runId === it.run_id && h.choice === 'postponed') {
            exists = true;
            break;
          }
        }
        if (exists) {
          continue;
        }

        const entry: ApproveRequest = new ApproveRequest();
        entry.runId = it.run_id;
        entry.command = it.command;
        entry.patterns = it.pattern_keys;
        entry.description = it.description;
        entry.sessionId = it.session_id;
        entry.receivedAt = Math.round(it.created_at * 1000);
        entry.choice = 'postponed';
        entry.handledAt = 0;
        this.history.unshift(entry);
        added++;
      }
      if (added > 0) {
        this.trimHistory();
        await this.persist();
        this.notify();
        console.info('approve syncFromServer: 补回 ' + added + ' 条未处理审批');
      }
      return added;
    } catch (e) {
      // 启动早期 rest 可能还没配好 → 静默，下次回前台会重试
      console.info('approve syncFromServer skipped: ' + (e as Error).message);
      return 0;
    }
  }

  /** 订阅变更，返回取消订阅的闭包 */
  public subscribe(cb: () => void): () => void {
    this.listeners.push(cb);
    return (): void => {
      const i: number = this.listeners.indexOf(cb);
      if (i >= 0) {
        this.listeners.splice(i, 1);
      }
    };
  }

  private notify(): void {
    for (const cb of this.listeners) {
      cb();
    }
  }

  /** 重置（登出/调试用） */
  public reset(): void {
    this.queue = [];
    this.current = null;
    this.inProgress = false;
    this.handled = [];
    this.notify();
  }
}

/** 全局单例 */
export const approveService: ApproveService = new ApproveService();

/** choice 的中文标签（审批历史展示用） */
export function choiceLabel(choice: string): string {
  if (choice === 'once') {
    return '仅本次放行';
  }
  if (choice === 'session') {
    return '本次会话放行';
  }
  if (choice === 'always') {
    return '始终允许';
  }
  if (choice === 'deny') {
    return '拒绝';
  }
  if (choice === 'postponed') {
    return '待处理';
  }
  if (choice === 'dismissed') {
    return '未处理（关闭）';
  }
  return choice;
}

/** 'HH:MM:SS'（审批历史展示用） */
export function clockText(ms: number): string {
  if (ms <= 0) {
    return '—';
  }
  const d: Date = new Date(ms);
  const hh: string = String(d.getHours()).padStart(2, '0');
  const mm: string = String(d.getMinutes()).padStart(2, '0');
  const ss: string = String(d.getSeconds()).padStart(2, '0');
  return hh + ':' + mm + ':' + ss;
}
