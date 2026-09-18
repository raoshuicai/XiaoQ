/**
 * ChatWsBridge —— WebSocket 协议到状态机的桥接层
 *
 * S7 引入。此前这些事全在 ChatPage 上：9 个事件订阅的注册/注销、8 个协议
 * 处理方法（sync_pending / sync_resume / notification / chat_token / chat_done /
 * chat_error / ws_connected / ws_disconnected）、以及订阅句柄的手工管理。
 * 其中 8 个处理方法里有 6 个是纯粹的 `engine.handleXxx()` 薄转发，
 * 放在页面里只增加噪音。
 *
 * 本层只做协议分发，不持有任何 UI 状态：
 *   - 需要改 UI 的（notification 弹 toast、approve 弹卡片）通过 WsBridgeHooks 回调出去
 *   - 其余直接喂给 ChatStreamEngine（它自己再回调页面）
 *
 * ⚠️ engine 用 getter 传入而不是直接传实例：engine 由页面在 aboutToAppear 里
 *    创建，时机可能晚于 connect。用 getter 保证每次事件都取到最新引用，
 *    否则会静默断链（事件来了但 engine 为 null，什么都不做）。
 */

import { eventBus, Events, Unsubscribe } from '../core/EventBus.ets';
import { wsService } from './WsService.ets';
import { WsMessage } from '../models/WsModels.ets';
import { ChatStreamEngine } from '../core/ChatStreamEngine.ets';

/** 页面侧需要自己处理的两件事（其余协议事件桥接层内部消化） */
export class WsBridgeHooks {
  /** 通知到达：页面弹 toast + 插消息 */
  onNotification: (msg: WsMessage) => void = () => {};
  /** 审批请求到达：交给全局审批中心 */
  onApprove: (msg: WsMessage) => void = () => {};
}

export class ChatWsBridge {
  private unsubs: Unsubscribe[] = [];

  /**
   * 连接并注册全部协议订阅。
   * @param baseUrl  服务地址
   * @param deviceId 设备 ID
   * @param getEngine 取当前状态机的 getter（可能尚未创建）
   * @param hooks 页面回调
   */
  public connect(baseUrl: string, deviceId: string,
                 getEngine: () => ChatStreamEngine | null, hooks: WsBridgeHooks): void {
    // 重复订阅会让同一条消息被处理多次，先全清
    this.teardown();

    wsService.connect(baseUrl, deviceId);

    // sync_pending_response：服务端补发了离线缓存内容
    this.unsubs.push(eventBus.on(Events.CHAT_SYNC_PENDING, (m: WsMessage): void => {
      // 内容为空 → 服务器还没准备好，engine 的 retry timer 会继续重试
      getEngine()?.handleSyncPending(m.content ?? '');
    }));

    // sync_resume：服务端通知流已恢复，后续 token 会实时推送
    this.unsubs.push(eventBus.on(Events.CHAT_SYNC_RESUME, (m: WsMessage): void => {
      getEngine()?.handleSyncResume(m.caught_up ?? 0);
    }));

    // notification：需要插进消息列表，交给页面
    this.unsubs.push(eventBus.on(Events.NOTIFICATION, (m: WsMessage): void => {
      hooks.onNotification(m);
    }));

    // chat_token：流式 token 到达
    this.unsubs.push(eventBus.on(Events.CHAT_TOKEN, (m: WsMessage): void => {
      if (m.content === undefined) {
        return;
      }
      getEngine()?.handleToken(m.content, m.seq, m.session_id ?? '');
    }));

    // chat_done：流式完成（落库与 UI 复位在 engine 的回调里）
    this.unsubs.push(eventBus.on(Events.CHAT_DONE, (): void => {
      getEngine()?.handleDone();
    }));

    // chat_error：流式失败（UI 展示在 engine 的回调里）
    this.unsubs.push(eventBus.on(Events.CHAT_ERROR, (m: WsMessage): void => {
      getEngine()?.handleError(m.message !== undefined ? m.message : '流式回复失败');
    }));

    // 审批请求：交给全局审批中心
    this.unsubs.push(eventBus.on(Events.APPROVE_REQUEST, (m: WsMessage): void => {
      hooks.onApprove(m);
    }));

    // WS 连上/断开：交给 engine 判断是否需要续流 / 插恢复占位符
    this.unsubs.push(eventBus.on(Events.WS_CONNECTED, (): void => {
      getEngine()?.handleConnected();
    }));
    this.unsubs.push(eventBus.on(Events.WS_DISCONNECTED, (): void => {
      getEngine()?.handleDisconnected();
    }));
  }

  /** 注销全部事件订阅 */
  public teardown(): void {
    for (let i: number = 0; i < this.unsubs.length; i++) {
      this.unsubs[i]();
    }
    this.unsubs = [];
  }
}

/** 全局单例 */
export const chatWsBridge: ChatWsBridge = new ChatWsBridge();
