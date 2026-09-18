/**
 * SessionModels —— 会话列表数据模型
 *
 * S12 引入。对照 xiaoq-api 的真实响应：
 *   GET /api/sessions?limit&offset
 *       -> {items:[{id,title,model,started_at,updated_at,message_count,tokens}],
 *           total, has_more}
 *   GET /api/sessions/{id}/messages?limit&offset
 *       -> {items:[{id,role,content,created_at}], total, has_more}
 *
 * 时间字段是秒级时间戳（服务端从 state.db 的 float 取整）。
 */

/** 会话列表项 */
export class SessionItem {
  id: string = '';
  /** 服务端可能没给（APP 自建会话通常没有 title）*/
  title: string = '';
  model: string = '';
  startedAt: number = 0;
  updatedAt: number = 0;
  messageCount: number = 0;
  tokens: number = 0;

  /** 展示用标题：有 title 用 title，否则用时间 + 消息数兜底 */
  displayTitle(): string {
    if (this.title.length > 0) {
      return this.title;
    }
    return '会话 ' + this.id.substring(0, 14);
  }
}

/** 会话里的一条消息 */
export class SessionMessage {
  id: number = 0;
  role: string = '';
  content: string = '';
  /** 秒级时间戳 */
  createdAt: number = 0;
}

/** 拉取结果（含分页信息）*/
export class SessionPage {
  items: SessionItem[] = [];
  total: number = 0;
  hasMore: boolean = false;
}

/** 消息拉取结果 */
export class MessagePage {
  items: SessionMessage[] = [];
  total: number = 0;
  hasMore: boolean = false;
}
