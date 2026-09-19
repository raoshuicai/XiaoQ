/**
 * ChatService —— 聊天消息持有与持久化
 *
 * S4 引入。从 ChatPage 收口三件事：
 *   1. 消息列表的持有（原 @State messageList + 十余处 push/splice 散落）
 *   2. 防抖持久化（原 scheduleSaveMessages，500ms 防抖）
 *   3. **LLM 上下文构建**（原散在 sendMessage 里的 history 拼装 + 占位符过滤）
 *      —— 这条尤其重要：UI 占位符「⏳ 正在恢复连接...」绝不能进 LLM 上下文
 *      （v2.0.7 的 #30 修复），收口成单一入口就不会有人漏加过滤。
 *
 * 持久化 key 从「全局单 key」改为「按会话分 key」（方案 V2 §7.1），
 * 并负责从旧 key 迁移历史数据。
 *
 * 分层约束：本文件属于 services/，不得 import 任何页面。
 */

import { common } from '@kit.AbilityKit';
import { ChatMessage, ChatRecord, StoredMessage } from '../models/ChatModels.ets';
import { Clock, NO_TIMER, systemClock } from '../core/Timers.ets';
import {
  hasSessionMessages, loadSessionMessages, saveSessionMessages,
  loadLegacyMessages, removeLegacyMessages
} from '../utils/PreferencesHelper.ets';

/** 持久化防抖间隔（原 ChatPage.scheduleSaveMessages 的 500ms，一字不改） */
const SAVE_DEBOUNCE: number = 500;
/** UI 占位符前缀 —— 带此前缀的消息不进 LLM 上下文 */
const PLACEHOLDER_PREFIX: string = '⏳ 正在恢复连接';
/** 单会话最多本地缓存条数（与原 MAX_SAVED_MESSAGES 一致） */
const MAX_MESSAGES: number = 200;

export class ChatService {
  private messages: ChatMessage[] = [];
  private clock: Clock;
  private ctx: common.Context | null = null;
  private sessionId: string = '';
  private saveTimer: number = NO_TIMER;

  constructor(clock: Clock) {
    this.clock = clock;
  }

  /** 绑定运行上下文与会话身份（页面初始化时调用） */
  public bind(ctx: common.Context, sessionId: string): void {
    this.ctx = ctx;
    this.sessionId = sessionId;
  }

  public getSessionId(): string {
    return this.sessionId;
  }

  public getMessages(): ChatMessage[] {
    return this.messages;
  }

  // ─────────────────────────── 变更操作 ───────────────────────────

  /** 追加一条消息（自动补 msg_id 并触发防抖持久化） */
  public append(role: string, content: string): void {
    const msg: ChatMessage = {
      role: role,
      content: content,
      msg_id: this.newMsgId(),
      createdAt: Date.now()        // S21：记下时间，气泡上方要显示
    };
    this.messages.push(msg);
    this.scheduleSave();
  }

  /** 整段替换消息列表（恢复历史 / 欢迎语场景） */
  public setMessages(list: ChatMessage[]): void {
    this.messages = list;
    this.scheduleSave();
  }

  public deleteAt(index: number): boolean {
    if (index < 0 || index >= this.messages.length) {
      return false;
    }
    this.messages.splice(index, 1);
    this.scheduleSave();
    return true;
  }

  /**
   * 用内容替换最后一条"正在恢复连接"占位符。
   * @returns 是否找到并替换（false 时调用方应改为 append）
   */
  public replaceIndicator(newContent: string): boolean {
    for (let i: number = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].content.startsWith(PLACEHOLDER_PREFIX)) {
        const replaced: ChatMessage = {
          role: 'assistant',
          content: newContent,
          msg_id: this.newMsgId()
        };
        this.messages.splice(i, 1, replaced);
        this.scheduleSave();
        return true;
      }
    }
    return false;
  }

  /**
   * 删除「恢复中」占位符消息（服务端确认该会话已无活跃流时用）。
   *
   * ⚠️ 与 replaceIndicator 的区别：replace 会留下一条**空内容**的 assistant 消息，
   *    视觉上是个空气泡，所以清场必须用删除。
   */
  public removeIndicator(): boolean {
    for (let i: number = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].content.startsWith(PLACEHOLDER_PREFIX)) {
        this.messages.splice(i, 1);
        this.scheduleSave();
        return true;
      }
    }
    return false;
  }

  /**
   * 消息列表里是否残留「恢复中」占位符。
   *
   * ⚠️ 典型场景：流被中断（切网络/APP 被杀）时插入了占位符，而下次启动时
   *    engine.pendingIndicator 已被 reset() 清成 false —— 没人再去问服务端，
   *    占位符就永久留在列表里（实测踩坑：会话一直显示「正在恢复连接」）。
   */
  public hasIndicator(): boolean {
    for (let i: number = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].content.startsWith(PLACEHOLDER_PREFIX)) {
        return true;
      }
    }
    return false;
  }

  /**
   * 清除所有「恢复中」占位符（APP 启动时调用）。
   *
   * ⚠️ 判据为什么成立：占位符只在**流中断的当下**被插入。APP 启动时从本地缓存
   *    加载到的占位符，必然是**上一次运行遗留**的 —— 那一轮流早就没了（进程都重启了），
   *    留着只会让界面永久卡在「正在恢复连接」（实测 app-ba0fbf3a7f / app-6615... 各挂一条）。
   *
   * ⚠️ 为什么不在切会话时也清：切会话发生在同一次运行内，此时占位符可能是**刚刚**因
   *    网络抖动插入的、流还活着，清掉会让用户丢失"正在恢复"的反馈。所以只在启动时清。
   *
   * 比"发 sync_pending 问服务端"可靠：不依赖 WS 连接状态、服务端响应和时序
   * （那套试过，三次都没触发 —— ChatWsBridge 的连接事件只在连上那一瞬调一次，
   *  自检永远赶不上）。
   */
  public purgeIndicators(): number {
    let removed: number = 0;
    for (let i: number = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].content.startsWith(PLACEHOLDER_PREFIX)) {
        this.messages.splice(i, 1);
        removed++;
      }
    }
    if (removed > 0) {
      this.scheduleSave();
      console.info('[ChatService] 启动清理：移除 ' + removed + ' 条遗留占位符');
    }
    return removed;
  }

  /**
   * 最近一条 assistant 消息是否就是这段内容（S19 去重）。
   *
   * ⚠️ 为什么需要：同一份回复可能走两条路进 APP ——
   *    ① APP 重连后 `GET /api/sessions/{id}/messages` 拉历史（其中已含该回复）
   *    ② `sync_pending` 命中 offline_chats 补投
   *    两者都到就会渲染出**两条一模一样的回复**（实测会话 app-42015772fca4497d）。
   *    服务端已修（拉历史后清缓存），客户端这层是双保险。
   */
  public isLastAssistantSame(content: string): boolean {
    const c: string = content.trim();
    if (c.length === 0) {
      return false;
    }
    for (let i: number = this.messages.length - 1; i >= 0; i--) {
      const m: ChatMessage = this.messages[i];
      if (m.role === 'assistant' && m.content.trim().length > 0) {
        return m.content.trim() === c;
      }
    }
    return false;
  }

  // ─────────────────────── LLM 上下文构建 ───────────────────────

  /**
   * 构建发给 LLM 的历史消息。
   * ⚠️ 统一在此过滤 UI 占位符 —— 历史上这里是"每处调用各写一遍过滤"，
   *    漏写就会把「⏳ 正在恢复连接...」喂给模型（真实踩过的坑）。
   */
  public buildHistoryForLlm(): ChatRecord[] {
    const history: ChatRecord[] = [];
    for (let i: number = 0; i < this.messages.length; i++) {
      const m: ChatMessage = this.messages[i];
      if (m.content.startsWith(PLACEHOLDER_PREFIX)) {
        continue;
      }
      history.push({ role: m.role, content: m.content });
    }
    return history;
  }

  // ─────────────────────────── 加载与迁移 ───────────────────────────

  /**
   * 从本地读取该会话的历史消息。
   *
   * 迁移流程（方案 V2 §7.1）：
   *   新 key 已存在 → 直接读（幂等，支持反复升降级）
   *   否则读旧 key → 补 msg_id → 写新 key → 校验条数 → 删旧 key
   *   任一步失败都保留旧 key（降级为可用，不阻塞启动）
   */
  public async loadSaved(): Promise<ChatMessage[]> {
    if (this.ctx === null || this.sessionId === '') {
      this.messages = [];
      return this.messages;
    }

    // 1) 新 key 已有数据 → 直接用
    const hasNew: boolean = await hasSessionMessages(this.ctx, this.sessionId);
    if (hasNew) {
      const saved: StoredMessage[] = await loadSessionMessages(this.ctx, this.sessionId);
      this.messages = this.toChatMessages(saved);
      console.info('[ChatService] 命中新 key，恢复 ' + this.messages.length + ' 条');
      return this.messages;
    }

    // 2) 迁移旧 key
    const legacy: StoredMessage[] = await loadLegacyMessages(this.ctx);
    if (legacy.length > 0) {
      const migrated: StoredMessage[] = this.migrateLegacy(legacy);
      await saveSessionMessages(this.ctx, this.sessionId, migrated);
      const verify: StoredMessage[] = await loadSessionMessages(this.ctx, this.sessionId);
      if (verify.length === migrated.length) {
        await removeLegacyMessages(this.ctx);
        console.info('[ChatService] 迁移完成: ' + migrated.length + ' 条（旧 key → 新 key）');
      } else {
        console.error('[ChatService] 迁移校验失败（写 ' + migrated.length
          + ' 读 ' + verify.length + '），保留旧 key 降级可用');
      }
      this.messages = this.toChatMessages(migrated);
      return this.messages;
    }

    // 3) 全新安装
    this.messages = [];
    return this.messages;
  }

  /** 给旧数据补 msg_id（幂等：已有 id 的原样保留） */
  private migrateLegacy(legacy: StoredMessage[]): StoredMessage[] {
    const base: number = Date.now();
    const out: StoredMessage[] = [];
    for (let i: number = 0; i < legacy.length; i++) {
      const m: StoredMessage = legacy[i];
      const hasId: boolean = m.msg_id !== undefined && m.msg_id !== '';
      out.push({
        role: m.role,
        content: m.content,
        msg_id: hasId ? m.msg_id : ('legacy-' + i.toString() + '-' + base.toString())
      });
    }
    return out;
  }

  // ─────────────────────────── 持久化 ───────────────────────────

  private scheduleSave(): void {
    if (this.saveTimer !== NO_TIMER) {
      this.clock.clearTimeout(this.saveTimer);
    }
    this.saveTimer = this.clock.setTimeout((): void => {
      this.saveTimer = NO_TIMER;
      this.flushNow();
    }, SAVE_DEBOUNCE);
  }

  /** 立即落盘（页面销毁、切会话等时机调用，别等防抖） */
  public flushNow(): void {
    if (this.ctx === null || this.sessionId === '') {
      return;
    }
    const toSave: StoredMessage[] = this.toStored(this.messages);
    saveSessionMessages(this.ctx, this.sessionId, toSave);
  }

  /**
   * flushNow 的**等待版**（S20）。
   *
   * ⚠️ 为什么需要：`flushNow()` 调的是 async 的写入但不 await —— 在"新会话建立"
   *    这个场景里紧接着就会读同一个 key（@Watch → loadSaved），会撞上竞态：
   *    读的时候还没写完 → 读到空 → 转去拉服务端历史 → 把本地刚聊的内容覆盖掉。
   *    所以那一步必须等写入真正完成。
   */
  public async flushNowAsync(): Promise<void> {
    if (this.ctx === null || this.sessionId === '') {
      return;
    }
    const toSave: StoredMessage[] = this.toStored(this.messages);
    await saveSessionMessages(this.ctx, this.sessionId, toSave);
  }

  public dispose(): void {
    if (this.saveTimer !== NO_TIMER) {
      this.clock.clearTimeout(this.saveTimer);
      this.saveTimer = NO_TIMER;
    }
    this.flushNow();
  }

  // ─────────────────────────── 内部工具 ───────────────────────────

  private newMsgId(): string {
    return 'm-' + Date.now().toString() + '-' + Math.floor(Math.random() * 100000).toString();
  }

  private toChatMessages(list: StoredMessage[]): ChatMessage[] {
    const out: ChatMessage[] = [];
    for (let i: number = 0; i < list.length; i++) {
      out.push({ role: list[i].role, content: list[i].content, msg_id: list[i].msg_id });
    }
    return out;
  }

  private toStored(list: ChatMessage[]): StoredMessage[] {
    const out: StoredMessage[] = [];
    const start: number = list.length > MAX_MESSAGES ? list.length - MAX_MESSAGES : 0;
    for (let i: number = start; i < list.length; i++) {
      out.push({ role: list[i].role, content: list[i].content, msg_id: list[i].msg_id });
    }
    return out;
  }
}

export const chatService: ChatService = new ChatService(systemClock);
