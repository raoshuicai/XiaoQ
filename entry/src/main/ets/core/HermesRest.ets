/**
 * HermesRest —— 统一 REST 客户端
 *
 * S5 引入。此前 HermesApi 与 FileApi **各自维护一份完全相同的 rcp 样板**
 * （同样的 baseAddress 处理、同样的 connectMs=15000 / transferMs=120000、
 * 同样的 Bearer 头拼装、同样的错误包装）。加一个新接口就要再复制一遍。
 *
 * 本类统一承担：baseUrl 规范化、认证头、JSON 编解码、错误归一、
 * 以及两条来自 MoA 评审的可靠性要求：
 *
 *   1. **延迟销毁**（MoA-2 #06 / S0 反馈）
 *      configure() 重建 session 时不能立刻 close 旧的 —— 若此时有在途请求
 *      （如同时拉会话列表 + Token 用量），会直接抛异常。改为标记待销毁，
 *      3 秒后统一关闭。
 *   2. **指数退避重试**（只针对网络层错误）
 *      rcp 在 HTTP 4xx/5xx 时**不抛异常**（正常返回 response），所以
 *      fetch 抛异常 == 网络层失败 == 可安全重试。最多重试 2 次（200ms → 600ms）。
 *
 * 分层约束：本文件属于 core/，不得 import 任何 ArkUI 或页面。
 */

import { rcp } from '@kit.RemoteCommunicationKit';

/** 网络类错误重试次数（不含首次） */
const MAX_RETRIES: number = 2;
/** 重试退避基数（毫秒）：第一次 200ms，第二次 600ms */
const RETRY_BASE_MS: number = 200;
/** 旧 session 延迟销毁延迟（毫秒） */
const DEFER_CLOSE_MS: number = 3000;
/** 请求超时（与原先两处实现保持一致） */
const CONNECT_TIMEOUT_MS: number = 15000;
const TRANSFER_TIMEOUT_MS: number = 120000;

export class HermesRest {
  private session: rcp.Session | null = null;
  private currentBaseUrl: string = '';
  private currentApiKey: string = '';
  /** 待销毁的旧 session（延迟关闭，避免打断在途请求） */
  private pendingClose: rcp.Session[] = [];
  private closeTimer: number = -1;

  /**
   * 配置（或重配置）客户端。
   * baseUrl / apiKey 未变化时不做任何事，避免无谓重建。
   */
  public configure(baseUrl: string, apiKey: string): void {
    const normalized: string = baseUrl.replace(/\/+$/, '');
    if (this.session !== null && this.currentBaseUrl === normalized && this.currentApiKey === apiKey) {
      return;
    }
    // 旧 session 不立刻关闭 —— 可能还有在途请求
    if (this.session !== null) {
      this.pendingClose.push(this.session);
      this.scheduleDeferredClose();
    }
    this.currentBaseUrl = normalized;
    this.currentApiKey = apiKey;
    this.session = this.createSession(normalized);
  }

  public isConfigured(): boolean {
    return this.currentBaseUrl !== '' && this.currentApiKey !== '';
  }

  public getBaseUrl(): string {
    return this.currentBaseUrl;
  }

  // ─────────────────────────── 请求方法 ───────────────────────────

  /** GET，query 会被 url-encode */
  public async get(path: string, query?: Record<string, string>): Promise<Object> {
    const url: string = this.buildUrl(path, query);
    const headers: Record<string, string> = this.authHeaders(false);
    const request: rcp.Request = new rcp.Request(url, 'GET', headers, {});
    const response: rcp.Response = await this.fetchWithRetry(request);
    return this.unwrap(response);
  }

  /** POST JSON */
  public async post(path: string, body: Object, extraHeaders?: Record<string, string>): Promise<Object> {
    const headers: Record<string, string> = this.authHeaders(true);
    if (extraHeaders !== undefined) {
      const keys: string[] = Object.keys(extraHeaders);
      for (let i: number = 0; i < keys.length; i++) {
        headers[keys[i]] = extraHeaders[keys[i]];
      }
    }
    const request: rcp.Request = new rcp.Request(path, 'POST', headers, body);
    const response: rcp.Response = await this.fetchWithRetry(request);
    return this.unwrap(response);
  }

  /**
   * 带副作用的调用（如审批响应）：**不做重试**，只发一次。
   * 原因：重试可能造成重复提交，副作用接口必须幂等由调用方保证。
   */
  public async postOnce(path: string, body: Object, extraHeaders?: Record<string, string>): Promise<Object> {
    const headers: Record<string, string> = this.authHeaders(true);
    if (extraHeaders !== undefined) {
      const keys: string[] = Object.keys(extraHeaders);
      for (let i: number = 0; i < keys.length; i++) {
        headers[keys[i]] = extraHeaders[keys[i]];
      }
    }
    const request: rcp.Request = new rcp.Request(path, 'POST', headers, body);
    const response: rcp.Response = await this.ensureSession().fetch(request);
    return this.unwrap(response);
  }

  public destroy(): void {
    this.closePendingNow();
    if (this.session !== null) {
      try {
        this.session.close();
      } catch (e) {
        // ignore
      }
      this.session = null;
    }
  }

  // ─────────────────────────── 内部实现 ───────────────────────────

  private buildUrl(path: string, query?: Record<string, string>): string {
    if (query === undefined) {
      return path;
    }
    const keys: string[] = Object.keys(query);
    if (keys.length === 0) {
      return path;
    }
    let url: string = path + '?';
    for (let i: number = 0; i < keys.length; i++) {
      if (i > 0) {
        url += '&';
      }
      url += encodeURIComponent(keys[i]) + '=' + encodeURIComponent(query[keys[i]]);
    }
    return url;
  }

  private authHeaders(json: boolean): Record<string, string> {
    const headers: Record<string, string> = {};
    if (json) {
      headers['Content-Type'] = 'application/json';
    }
    if (this.currentApiKey !== '') {
      headers['Authorization'] = 'Bearer ' + this.currentApiKey;
    }
    return headers;
  }

  private createSession(baseUrl: string): rcp.Session | null {
    try {
      const config: rcp.SessionConfiguration = {
        baseAddress: baseUrl,
        requestConfiguration: {
          transfer: {
            autoRedirect: true,
            timeout: {
              connectMs: CONNECT_TIMEOUT_MS,
              transferMs: TRANSFER_TIMEOUT_MS
            }
          }
        }
      };
      return rcp.createSession(config);
    } catch (error) {
      console.error('[HermesRest] createSession failed: ' + error);
      return null;
    }
  }

  private ensureSession(): rcp.Session {
    if (this.session === null) {
      this.session = this.createSession(this.currentBaseUrl);
    }
    if (this.session === null) {
      throw new Error('网络连接创建失败');
    }
    return this.session;
  }

  /** 带退避重试的 fetch（仅网络层异常才重试） */
  private async fetchWithRetry(request: rcp.Request): Promise<rcp.Response> {
    let lastError: Error | null = null;
    for (let attempt: number = 0; attempt <= MAX_RETRIES; attempt++) {
      if (attempt > 0) {
        const waitMs: number = RETRY_BASE_MS * (attempt === 1 ? 1 : 3);
        await HermesRest.sleep(waitMs);
        console.info('[HermesRest] retry #' + attempt + ' after ' + waitMs + 'ms');
      }
      try {
        return await this.ensureSession().fetch(request);
      } catch (error) {
        // rcp 只在网络层失败时抛异常 → 可安全重试
        lastError = error instanceof Error ? (error as Error) : new Error(String(error));
      }
    }
    throw lastError !== null ? lastError : new Error('请求失败');
  }

  /** 统一解包：200 返回 JSON，其余抛带状态码的错误 */
  private unwrap(response: rcp.Response): Object {
    const status: number = response.statusCode;
    if (status === 200) {
      return response.toJSON() as Object;
    }
    let detail: string = '';
    try {
      // ArkTS：toString() 返回 string | null，不能直接赋给 string
      const raw: string | null = response.toString();
      detail = raw !== null ? raw : '';
    } catch (e) {
      detail = '';
    }
    throw new Error('HTTP ' + status + (detail !== '' ? ': ' + detail : ''));
  }

  private scheduleDeferredClose(): void {
    if (this.closeTimer !== -1) {
      return;
    }
    this.closeTimer = setTimeout((): void => {
      this.closeTimer = -1;
      this.closePendingNow();
    }, DEFER_CLOSE_MS);
  }

  private closePendingNow(): void {
    if (this.closeTimer !== -1) {
      clearTimeout(this.closeTimer);
      this.closeTimer = -1;
    }
    for (let i: number = 0; i < this.pendingClose.length; i++) {
      try {
        this.pendingClose[i].close();
      } catch (e) {
        // ignore
      }
    }
    this.pendingClose = [];
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }
}

export const rest: HermesRest = new HermesRest();
