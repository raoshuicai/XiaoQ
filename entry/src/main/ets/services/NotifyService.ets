/**
 * NotifyService —— 通知中心数据访问 + 全局未读数
 *
 * S9 引入。服务端的 push 接口此前只有「写」没有「读」，消息只能靠 WS 推送当场
 * 落到聊天流里，翻不回去。本层把读、已读、未读计数补齐。
 *
 * 未读数放在 AppStorage（key: 'unreadCount'），让 AppHeader 的角标能跨组件响应：
 *   - WS 通知到达 → 页面调 bumpUnread()
 *   - 进通知页标已读 → refreshUnread() 拉服务端真值
 * 单一数据源是服务端（DB），AppStorage 只是缓存，避免各处自行加减导致漂移。
 */

import { rest } from '../core/HermesRest.ets';
import { PushMessage } from '../models/NotifyModels.ets';

/** AppStorage 里未读数的 key（AppHeader 用 @StorageLink 绑同一个 key） */
export const UNREAD_KEY: string = 'unreadCount';

export class NotifyService {
  /** 拉取通知列表（新→旧） */
  public async fetchMessages(limit: number, unreadOnly: boolean): Promise<PushMessage[]> {
    const q: Record<string, string> = {
      'limit': String(limit),
      'unread_only': unreadOnly ? 'true' : 'false'
    };
    const raw: Record<string, Object> = await rest.get('/api/push/messages', q) as Record<string, Object>;
    const out: PushMessage[] = [];
    const arr: Object[] = (raw['messages'] as Object[]) ?? [];
    for (const item of arr) {
      const r: Record<string, Object> = item as Record<string, Object>;
      const m: PushMessage = new PushMessage();
      m.id = NotifyService.num(r, 'id');
      m.title = NotifyService.str(r, 'title');
      m.body = NotifyService.str(r, 'body');
      m.source = NotifyService.str(r, 'source');
      m.createdAt = NotifyService.str(r, 'created_at');
      m.readAt = NotifyService.str(r, 'read_at');
      out.push(m);
    }
    return out;
  }

  /** 拉服务端真实未读数并同步到 AppStorage，返回该值 */
  public async refreshUnread(): Promise<number> {
    const raw: Record<string, Object> = await rest.get('/api/push/unread') as Record<string, Object>;
    const n: number = NotifyService.num(raw, 'unread_count');
    AppStorage.setOrCreate(UNREAD_KEY, n);
    return n;
  }

  /** 本地 +1（WS 通知到达时用，避免每次都打接口） */
  public bumpUnread(): void {
    const cur: number = AppStorage.get<number>(UNREAD_KEY) as number ?? 0;
    AppStorage.setOrCreate(UNREAD_KEY, cur + 1);
  }

  /** 全部标已读，返回实际更新条数 */
  public async markAllRead(): Promise<number> {
    const body: Record<string, Object> = { 'all': true };
    const raw: Record<string, Object> = await rest.post('/api/push/read', body) as Record<string, Object>;
    const n: number = NotifyService.num(raw, 'updated');
    await this.refreshUnread();
    return n;
  }

  /** 按 id 标已读，返回实际更新条数 */
  public async markRead(ids: number[]): Promise<number> {
    if (ids.length === 0) {
      return 0;
    }
    const body: Record<string, Object> = { 'ids': ids };
    const raw: Record<string, Object> = await rest.post('/api/push/read', body) as Record<string, Object>;
    const n: number = NotifyService.num(raw, 'updated');
    await this.refreshUnread();
    return n;
  }

  private static num(o: Record<string, Object>, key: string): number {
    const v: Object | undefined = o[key];
    return typeof v === 'number' ? v as number : 0;
  }

  private static str(o: Record<string, Object>, key: string): string {
    const v: Object | undefined = o[key];
    // 服务端未读时 read_at 为 None -> JSON null -> 这里落成空串
    if (typeof v === 'string') {
      return v as string;
    }
    return '';
  }
}

export const notifyService: NotifyService = new NotifyService();

/** 把 '2026-09-18 06:11:23' 缩成 '09-18 06:11' */
export function shortTime(s: string): string {
  if (s.length >= 16) {
    return s.substring(5, 16);
  }
  return s;
}

/** 角标文案：超过 99 显示 99+ */
export function badgeText(n: number): string {
  if (n <= 0) {
    return '';
  }
  return n > 99 ? '99+' : String(n);
}
