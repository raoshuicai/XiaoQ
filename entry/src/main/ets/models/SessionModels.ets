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

  /**
   * 跨端可见性三件套（服务端 /api/sessions 已返回，此前客户端没接）：
   *   source   —— 这条会话是哪一端建的：api_server(本机 APP) / desktop / webui / cli / feishu ...
   *   activity —— 另一端此刻在干什么（'terminal command running (40s elapsed)'）
   *   active   —— 另一端是否正在这一轮里跑（服务端按 90 秒活动窗口判定）
   */
  source: string = '';
  activity: string = '';
  active: boolean = false;

  /** 展示用标题：有 title 用 title，否则用时间 + 消息数兜底 */
  displayTitle(): string {
    if (this.title.length > 0) {
      return this.title;
    }
    return '会话 ' + this.id.substring(0, 14);
  }

  /**
   * 来源角标文案。本机 APP 自己发起的会话（source=api_server）返回空串 —— 不显示角标，
   * 免得整屏都是「手机」标签反而看不出哪条是跨端的。
   */
  sourceLabel(): string {
    if (this.source === 'desktop') {
      return '桌面';
    }
    if (this.source === 'webui') {
      return 'WebUI';
    }
    if (this.source === 'cli' || this.source === 'tui') {
      return 'CLI';
    }
    if (this.source === 'feishu') {
      return '飞书';
    }
    if (this.source === 'telegram') {
      return 'TG';
    }
    if (this.source === 'weixin') {
      return '微信';
    }
    if (this.source === 'ntfy') {
      return '通知';
    }
    return '';
  }

  /** 是不是「另一端」的会话（非本机 APP 建的） */
  isForeign(): boolean {
    return this.source.length > 0 && this.source !== 'api_server';
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
/**
 * 跨端轮询探针（2026-10-27）
 * 只含「有没有变化」需要的字段：
 *   lastMsgId —— 末条有效消息 id（判断有新增）
 *   lastLen   —— 末条正文长度（判断正文被回填：id 不变但内容变了）
 */
export class SessionMeta {
  id: string = '';
  source: string = '';
  active: boolean = false;
  activity: string = '';
  messageCount: number = 0;
  lastMsgId: number = 0;
  lastLen: number = 0;
}

export class MessagePage {
  items: SessionMessage[] = [];
  total: number = 0;
  hasMore: boolean = false;
  /**
   * 会话级状态（服务端 messages 接口随包返回）：
   *   跨端会话在轮询历史时，靠这三个字段判断「对面还在跑没有、跑到哪一步」。
   */
  source: string = '';
  activity: string = '';
  active: boolean = false;
}
