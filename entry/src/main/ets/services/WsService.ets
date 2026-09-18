/**
 * WsService —— WebSocket 连接与消息分发
 *
 * S2 引入。职责边界（严格按方案 V2 §5 S2 的逐块归属表）：
 *   本服务**只做"分派壳"** —— 收到消息后按 type 转发到 EventBus。
 *   消息的**处理逻辑**（token 累积 / seq 推进 / 计时器 / 占位符过滤）
 *   在 S2 阶段**原样保留在 ChatPage**，由 S3 搬进 ChatStreamEngine。
 *
 * ⚠️ 不要在本文件里加业务逻辑 —— 否则 S3 就没有东西可抽了
 *    （MoA-1 #1 指出的 S2/S3 边界重叠问题）。
 *
 * 连接细节（心跳 15s / 重连 2s / 待发队列 / disconnectNotified 防重入）
 * 全部由 WebSocketClient 内部负责，本服务不重复实现、也不重复保存连接状态。
 *
 * 分层约束：本文件属于 services/，不得 import 任何页面。
 */

import { WebSocketClient } from '../utils/WebSocketClient.ets';
import { WsMessage } from '../models/WsModels.ets';
import { eventBus, Events } from '../core/EventBus.ets';

export class WsService {
  private client: WebSocketClient = new WebSocketClient('pending');
  private deviceId: string = '';

  /**
   * 建立连接。
   * ⚠️ MoA-1 #8 / S0 反馈 2：调用方必须先 await 到真实 device_id 再调用本方法，
   * 否则会先用 'pending' 建一条垃圾连接（S0 实测每次启动都有两条 WS 连接）。
   * 修复动作在 S2 的 ChatPage.connectAfterDeviceIdReady()。
   */
  public connect(httpBaseUrl: string, deviceId: string): void {
    // ⚠️ device_id 未就绪时绝不建连接 —— 否则会先用 'pending' 建一条垃圾连接，
    // 随后真实 device_id 到达时再关掉重建，造成启动期连接抖动
    // （S0 实测每次启动两条 WS 连接；MoA-1 #8 / S0 反馈 2）
    if (deviceId === '') {
      console.warn('WsService.connect skipped: device_id not ready');
      return;
    }
    this.deviceId = deviceId;
    this.client.clientId = deviceId;
    this.client.setCallbacks(
      (msg: WsMessage): void => {
        this.dispatch(msg);
      },
      (): void => {
        eventBus.emit(Events.WS_CONNECTED, { type: Events.WS_CONNECTED });
      },
      (): void => {
        eventBus.emit(Events.WS_DISCONNECTED, { type: Events.WS_DISCONNECTED });
      }
    );
    // WiFi 走 ws://，公网走 wss://
    const wsBase: string = httpBaseUrl.startsWith('https')
      ? httpBaseUrl.replace('https', 'wss')
      : httpBaseUrl.replace('http', 'ws');
    this.client.connect(wsBase);
  }

  /**
   * 消息分派表。
   * ⚠️ sync_pending_response 与 sync_resume 是**两个独立事件**，
   * 不可合并（MoA-1 #2）。前者携带"补发的完整内容"，后者只是"流已恢复"通知。
   */
  private dispatch(msg: WsMessage): void {
    const table: Map<string, string> = new Map<string, string>([
      ['chat_token', Events.CHAT_TOKEN],
      ['chat_done', Events.CHAT_DONE],
      ['chat_error', Events.CHAT_ERROR],
      ['sync_resume', Events.CHAT_SYNC_RESUME],
      ['sync_pending_response', Events.CHAT_SYNC_PENDING],
      ['approve_request', Events.APPROVE_REQUEST],
      ['notification', Events.NOTIFICATION]
    ]);
    const ev: string | undefined = table.get(msg.type);
    if (ev !== undefined) {
      eventBus.emit(ev, msg);
    }
  }

  public getDeviceId(): string {
    return this.deviceId;
  }

  public send(msg: WsMessage): void {
    this.client.send(msg);
  }

  public isConnected(): boolean {
    return this.client.isConnected();
  }

  public close(): void {
    this.client.close();
  }
}

export const wsService: WsService = new WsService();
