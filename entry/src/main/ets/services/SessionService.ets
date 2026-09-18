/**
 * SessionService —— 会话列表 / 会话消息数据访问
 *
 * S12 引入。服务端两个只读接口（S12a）已就绪，本层只做取数 + 映射。
 *
 * 会话身份模型（S12 起）：
 *   以前 session_id 固定 = device_id，导致 APP 只有一个会话。
 *   现在 session_id 是真正的「会话 ID」：
 *     - 首次进入 APP 仍用 device_id 作为默认会话（历史消息不丢）
 *     - 点「新会话」时置空 -> 发消息时服务端生成 `app-{uuid}` 并回执 chat_started
 *     - 之后该会话的 ID 就固定下来，可续聊
 */

import { rest } from '../core/HermesRest.ets';
import { SessionItem, SessionMessage, SessionPage, MessagePage } from '../models/SessionModels.ets';

export class SessionService {
  /** 会话题列表（按 updated_at 倒序）*/
  public async fetchSessions(limit: number, offset: number): Promise<SessionPage> {
    const q: Record<string, string> = {
      'limit': String(limit),
      'offset': String(offset)
    };
    const raw: Record<string, Object> = await rest.get('/api/sessions', q) as Record<string, Object>;
    const out: SessionPage = new SessionPage();
    out.total = SessionService.num(raw, 'total');
    out.hasMore = raw['has_more'] === true;
    const arr: Object[] = (raw['items'] as Object[]) ?? [];
    for (const it of arr) {
      const r: Record<string, Object> = it as Record<string, Object>;
      const s: SessionItem = new SessionItem();
      s.id = SessionService.str(r, 'id');
      s.title = SessionService.str(r, 'title');
      s.model = SessionService.str(r, 'model');
      s.startedAt = SessionService.num(r, 'started_at');
      s.updatedAt = SessionService.num(r, 'updated_at');
      s.messageCount = SessionService.num(r, 'message_count');
      s.tokens = SessionService.num(r, 'tokens');
      out.items.push(s);
    }
    return out;
  }

  /**
   * 某会话的消息。
   * offset 语义 = 从最新往历史翻的窗口偏移；返回始终是时间正序。
   */
  public async fetchMessages(sessionId: string, limit: number, offset: number): Promise<MessagePage> {
    const q: Record<string, string> = {
      'limit': String(limit),
      'offset': String(offset)
    };
    const raw: Record<string, Object> = await rest.get(
      '/api/sessions/' + encodeURIComponent(sessionId) + '/messages', q
    ) as Record<string, Object>;

    const out: MessagePage = new MessagePage();
    out.total = SessionService.num(raw, 'total');
    out.hasMore = raw['has_more'] === true;
    const arr: Object[] = (raw['items'] as Object[]) ?? [];
    for (const it of arr) {
      const r: Record<string, Object> = it as Record<string, Object>;
      const m: SessionMessage = new SessionMessage();
      m.id = SessionService.num(r, 'id');
      m.role = SessionService.str(r, 'role');
      m.content = SessionService.str(r, 'content');
      m.createdAt = SessionService.num(r, 'created_at');
      out.items.push(m);
    }
    return out;
  }

  private static str(o: Record<string, Object>, key: string): string {
    const v: Object | undefined = o[key];
    return typeof v === 'string' ? v as string : '';
  }

  private static num(o: Record<string, Object>, key: string): number {
    const v: Object | undefined = o[key];
    return typeof v === 'number' ? v as number : 0;
  }
}

export const sessionService: SessionService = new SessionService();

/** 秒级时间戳 -> 'MM-DD HH:MM'；今天则只显示 'HH:MM' */
export function sessionTime(sec: number): string {
  if (sec <= 0) {
    return '—';
  }
  const d: Date = new Date(sec * 1000);
  const now: Date = new Date();
  const hh: string = String(d.getHours()).padStart(2, '0');
  const mm: string = String(d.getMinutes()).padStart(2, '0');
  const sameDay: boolean = d.getFullYear() === now.getFullYear()
    && d.getMonth() === now.getMonth() && d.getDate() === now.getDate();
  if (sameDay) {
    return hh + ':' + mm;
  }
  const mo: string = String(d.getMonth() + 1).padStart(2, '0');
  const dd: string = String(d.getDate()).padStart(2, '0');
  return mo + '-' + dd + ' ' + hh + ':' + mm;
}

/** 相对时间：刚刚 / N 分钟前 / N 小时前 / MM-DD */
export function relativeTime(sec: number): string {
  if (sec <= 0) {
    return '—';
  }
  const diff: number = Math.floor(Date.now() / 1000) - sec;
  if (diff < 60) {
    return '刚刚';
  }
  if (diff < 3600) {
    return Math.floor(diff / 60) + ' 分钟前';
  }
  if (diff < 86400) {
    return Math.floor(diff / 3600) + ' 小时前';
  }
  return sessionTime(sec);
}
