/**
 * ApproveService —— 全局审批中心
 *
 * S7 引入。解决的问题（MoA-2 #08 / 风险清单 #11）：
 *   原先审批状态（showDialog / approveRunId / approveCommand / approvePatterns /
 *   approveInProgress）全部长在 ChatPage 上 —— 意味着**用户不在聊天页时，
 *   审批到达就没人接收**，只能等超时。而审批是 Gateway 侧阻塞等待的，
 *   超时等于任务失败。
 *
 * 现在改为：任何页面都能收到并处理审批。本服务负责
 *   1. 队列：同时到达多个审批请求时排队，一次只展示一个（不叠多张卡片）
 *   2. 去重：同一个 run_id 重复推送只入队一次（WS 重连会重放）
 *   3. 已处理登记：处理过的 run_id 不再弹（防重连后复活）
 *   4. 活跃页面判定：由各页面在 onPageShow/onPageHide 里登记，
 *      只有前台页面渲染卡片（避免多个页面各弹一张）
 *   5. 提交：自己调 HermesRest 提交（不依赖 ChatPage）
 *
 * ⚠️ 本类刻意不做成 @Observed：订阅者用回调 + 各自 @State 承接，
 *    比 @Observed 深层观测更可控（ArkUI 对非组件类的观测有诸多限制）。
 */

import { rest } from '../core/HermesRest.ets';
import { apiConfig } from '../core/ApiConfig.ets';

/** 一次审批请求 */
export class ApproveRequest {
  runId: string = '';
  command: string = '';
  patterns: string[] = [];

  constructor(runId: string, command: string, patterns: string[]) {
    this.runId = runId;
    this.command = command;
    this.patterns = patterns;
  }
}

export class ApproveService {
  /** 待处理队列（current 之外的） */
  private queue: ApproveRequest[] = [];
  /** 当前展示中的请求 */
  private current: ApproveRequest | null = null;
  /** 提交中 */
  private inProgress: boolean = false;
  /** 已处理过的 run_id（防重连重放复活） */
  private handled: string[] = [];
  /** 当前前台页面名（只有它的卡片会渲染） */
  private activePage: string = '';
  /** 变更订阅者 */
  private listeners: Array<() => void> = [];

  /** 入队（WS 收到 approve_request 时调用） */
  public push(runId: string, command: string, patterns: string[]): void {
    if (runId.length === 0) {
      return;
    }
    // 已处理过 → 忽略（WS 重连重放）
    if (this.handled.indexOf(runId) >= 0) {
      return;
    }
    // 已在队列或正展示 → 忽略
    if (this.current !== null && this.current.runId === runId) {
      return;
    }
    for (const q of this.queue) {
      if (q.runId === runId) {
        return;
      }
    }

    this.queue.push(new ApproveRequest(runId, command, patterns));
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
      this.handled.push(req.runId);
      this.current = null;
      this.inProgress = false;
      this.promoteIfIdle();
      this.notify();
      return true;
    } catch (e) {
      // 提交失败：保留卡片让用户重试（不清队列、不登记 handled）
      this.inProgress = false;
      this.notify();
      return false;
    }
  }

  /** 用户点遮罩关闭（仅收起 UI，请求仍留在队列，超时由服务端处理） */
  public dismissCurrent(): void {
    const req: ApproveRequest | null = this.current;
    if (req !== null) {
      this.handled.push(req.runId);
    }
    this.current = null;
    this.inProgress = false;
    this.promoteIfIdle();
    this.notify();
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
