/**
 * NotifyModels —— 通知中心数据模型
 *
 * S9 引入。对照 xiaoq-api 的真实响应（/api/push/messages、/api/push/unread）：
 *   GET  /api/push/messages?limit=&unread_only=  -> {messages:[{id,title,body,source,created_at,read_at}], total}
 *   GET  /api/push/unread                        -> {unread_count, latest:{id,title,body,created_at}|null}
 *   POST /api/push/read   {ids:[...]}|{all:true} -> {status, updated}
 */

/** 服务端存储的 push_messages 表里的一行 */
export class PushMessage {
  id: number = 0;
  title: string = '';
  body: string = '';
  /** 来源，服务端默认 'intel' */
  source: string = '';
  /** 'YYYY-MM-DD HH:MM:SS'（服务端按 +8 时区写入） */
  createdAt: string = '';
  /** 空字符串 = 未读（服务端用 NULL 表示未读） */
  readAt: string = '';
}
