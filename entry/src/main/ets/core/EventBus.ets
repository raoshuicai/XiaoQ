/**
 * EventBus —— 发布订阅事件总线
 *
 * S2 引入。目的：把 WebSocket 消息从"只能由 ChatPage 消费"解耦出来，
 * 让后续的通知页、审批队列、未读角标都能独立订阅同一批事件。
 *
 * 设计要点（全部来自 MoA 评审意见，见方案 V2 §3 决策 2）：
 *  1. `on()` 返回 Unsubscribe 闭包 —— 不依赖引用匹配来注销。
 *     MoA-1 #9 / MoA-2 #03：原设计用 indexOf 匹配，只要 on/off 传的不是
 *     同一个引用（如 on 传箭头函数、off 传裸方法引用），off 就静默失败，
 *     导致同一消息被消费 N 次 + Map 强引用组件闭包造成内存泄漏。
 *  2. 内部用 Set 去重 —— 防同一 handler 重复注册。
 *  3. emit 前复制快照 —— handler 内部可能 unsubscribe 自己。
 *  4. 单个 handler 抛异常不拖垮整轮分发。
 *
 * 分层约束：本文件属于 core/，不得 import 任何 ArkUI 或业务模块。
 */

import { WsMessage } from '../models/WsModels.ets';

export type EventHandler = (payload: WsMessage) => void;
export type Unsubscribe = () => void;

class EventBusImpl {
  private handlers: Map<string, Set<EventHandler>> = new Map();

  /**
   * 订阅事件。返回值必须在组件 aboutToDisappear 时调用 —— 否则重复订阅
   * 会导致同一条消息被处理多次（UI 消息翻倍的经典成因）。
   */
  public on(event: string, h: EventHandler): Unsubscribe {
    let set: Set<EventHandler> | undefined = this.handlers.get(event);
    if (set === undefined) {
      set = new Set<EventHandler>();
      this.handlers.set(event, set);
    }
    set.add(h);
    const target: Set<EventHandler> = set;
    return (): void => {
      target.delete(h);
    };
  }

  public emit(event: string, payload: WsMessage): void {
    const set: Set<EventHandler> | undefined = this.handlers.get(event);
    if (set === undefined) {
      return;
    }
    // 复制快照：handler 内部可能调用 unsubscribe 修改集合本身
    const snapshot: EventHandler[] = [];
    set.forEach((h: EventHandler): void => {
      snapshot.push(h);
    });
    for (let i: number = 0; i < snapshot.length; i++) {
      try {
        snapshot[i](payload);
      } catch (e) {
        // ArkTS：catch 参数类型不明确，显式归一化，禁止直接拼接 Object
        const msg: string = e instanceof Error ? (e as Error).message : JSON.stringify(e);
        console.error(`EventBus handler error [${event}]: ${msg}`);
      }
    }
  }

  /** 清空全部订阅（仅测试/调试用；正常运行靠 Unsubscribe 精准注销） */
  public clearAll(): void {
    this.handlers.clear();
  }
}

export const eventBus: EventBusImpl = new EventBusImpl();

/**
 * 事件名常量。
 *
 * ⚠️ 归属：事件名**只在本文件定义**（MoA-1 #10 指出 V1 方案里
 * EventBus 与 WsModels 两处定义互相矛盾）。models/WsModels.ets 只放纯类型。
 */
export class Events {
  static readonly WS_CONNECTED: string = 'ws.connected';
  static readonly WS_DISCONNECTED: string = 'ws.disconnected';
  static readonly CHAT_TOKEN: string = 'chat.token';
  static readonly CHAT_DONE: string = 'chat.done';
  static readonly CHAT_ERROR: string = 'chat.error';
  static readonly CHAT_SYNC_RESUME: string = 'chat.sync_resume';
  /** sync_pending_response 独立事件 —— 它与 sync_resume 语义不同，不可混用
   *  （MoA-1 #2：混用会导致"补发 token"这条续流路径失去归属）*/
  static readonly CHAT_SYNC_PENDING: string = 'chat.sync_pending';
  /** S12：服务端确认了本轮所属会话（新建会话时 APP 据此记住 ID） */
  static readonly CHAT_STARTED: string = 'chat.started';
  static readonly APPROVE_REQUEST: string = 'approve.request';
  static readonly NOTIFICATION: string = 'notification';
}
