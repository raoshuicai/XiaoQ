import { webSocket } from '@kit.NetworkKit';
import { WsMessage, WsCallback } from '../models/WsModels.ets';

const WS_PING_INTERVAL: number = 15000;  // 15秒心跳（原30秒，隧道不稳定需更快检测断线）
const WS_RECONNECT_DELAY: number = 2000; // 断线重连延时2秒（原5秒）

export class WebSocketClient {
  private ws: webSocket.WebSocket | null = null;
  private url: string = '';
  public clientId: string = '';
  private connected: boolean = false;
  private pingTimer: number | undefined = undefined;
  private reconnectTimer: number | undefined = undefined;
  private onMessage: WsCallback | undefined = undefined;
  private onConnect: (() => void) | undefined = undefined;
  private onDisconnect: (() => void) | undefined = undefined;
  private disconnectNotified: boolean = false;  // 防重入标志位（issue #14）
  private pendingQueue: WsMessage[] = [];  // WS 未连接时暂存消息，连上后自动排空

  constructor(clientId: string) {
    this.clientId = clientId;
  }

  public setCallbacks(onMessage: WsCallback, onConnect?: () => void, onDisconnect?: () => void): void {
    this.onMessage = onMessage;
    this.onConnect = onConnect;
    this.onDisconnect = onDisconnect;
  }

  public connect(url: string): void {
    this.url = url;
    this.doConnect();
  }

  private doConnect(): void {
    if (this.ws !== null) {
      this.close();
    }

    this.disconnectNotified = false;

    try {
      const fullUrl: string = this.url + '/ws/push?client_id=' + this.clientId;
      this.ws = webSocket.createWebSocket();

      this.ws.on('open', () => {
        this.connected = true;
        if (this.onConnect !== undefined) {
          this.onConnect();
        }
        this.startPing();
        // 排空待发送队列（WS 断线期间积压的消息）
        this.drainPendingQueue();
      });

      this.ws.on('message', (err: Error, data: string | ArrayBuffer) => {
        if (err !== null && err !== undefined) {
          console.error('WS message error: ' + err);
          return;
        }
        try {
          const msg: WsMessage = JSON.parse(data as string) as WsMessage;
          if (msg.type === 'pong') {
            return; // 心跳回复，忽略
          }
          if (this.onMessage !== undefined) {
            this.onMessage(msg);
          }
        } catch (error) {
          console.error('WS parse error: ' + error);
        }
      });

      this.ws.on('close', () => {
        this.connected = false;
        this.stopPing();
        if (!this.disconnectNotified && this.onDisconnect !== undefined) {
          this.disconnectNotified = true;
          this.onDisconnect();
        }
        this.scheduleReconnect();
      });

      this.ws.on('error', () => {
        this.connected = false;
        this.stopPing();
        if (!this.disconnectNotified && this.onDisconnect !== undefined) {
          this.disconnectNotified = true;
          this.onDisconnect();
        }
        this.scheduleReconnect();
      });

      this.ws.connect(fullUrl, (err: Error) => {
        if (err !== null && err !== undefined) {
          console.error('WS connect error: ' + err);
          this.scheduleReconnect();
        }
      });
    } catch (error) {
      console.error('WS creation failed: ' + error);
      this.scheduleReconnect();
    }
  }

  public send(msg: WsMessage): void {
    if (this.ws !== null && this.connected) {
      try {
        this.ws.send(JSON.stringify(msg));
      } catch (error) {
        console.error('WS send error: ' + error);
      }
    } else {
      // WS 未连接时入队，等待重连后自动排空
      this.pendingQueue.push(msg);
      console.info('WS queued message (type=' + msg.type + '), queue length=' + this.pendingQueue.length);
    }
  }

  public sendPing(): void {
    this.send({ type: 'ping' });
  }

  private startPing(): void {
    this.stopPing();
    this.pingTimer = setInterval(() => {
      this.sendPing();
    }, WS_PING_INTERVAL);
  }

  private stopPing(): void {
    if (this.pingTimer !== undefined) {
      clearInterval(this.pingTimer);
      this.pingTimer = undefined;
    }
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer !== undefined) {
      return; // 已安排重连
    }
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      if (!this.connected) {
        this.doConnect();
      }
    }, WS_RECONNECT_DELAY);
  }

  public close(): void {
    this.stopPing();
    if (this.reconnectTimer !== undefined) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = undefined;
    }
    if (this.ws !== null) {
      try {
        this.ws.off('open');
        this.ws.off('message');
        this.ws.off('close');
        this.ws.off('error');
        this.ws.close();
      } catch (error) {
        // ignore close errors
      }
      this.ws = null;
    }
    this.connected = false;
  }

  // 排空待发送队列：WS 断线期间积压的消息按顺序发出
  private drainPendingQueue(): void {
    while (this.pendingQueue.length > 0) {
      const msg: WsMessage = this.pendingQueue.shift()!;
      try {
        this.ws?.send(JSON.stringify(msg));
        console.info('WS drained queued message (type=' + msg.type + '), remaining=' + this.pendingQueue.length);
      } catch (error) {
        console.error('WS drain error: ' + error);
        break;
      }
    }
  }

  public isConnected(): boolean {
    return this.connected;
  }
}
