import { webSocket } from '@kit.NetworkKit';
import { WsMessage, WsCallback } from '../models/WsModels.ets';

const WS_PING_INTERVAL: number = 15000;  // 15秒心跳（原30秒，隧道不稳定需更快检测断线）
const WS_RECONNECT_DELAY: number = 2000; // 断线重连延时2秒（原5秒）
// V4-A1（N5）：看门狗阈值 90s ≈ 6 个 ping 周期，对齐 ChatStreamEngine stall 下限。
//   路线一不做 create_task，长工具静默期服务端不回 pong，60s 会误重连（M-4 拦的正是这个）。
//   一切入站帧（token/progress/pong/…）都刷新 lastAliveAt → 静默期靠 chat_progress 续命。
const WS_ALIVE_TIMEOUT: number = 90000;

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
  private lastAliveAt: number = 0;  // V4-A1：最近一次入站时间（任何帧都刷新，含 pong）

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
        this.lastAliveAt = Date.now();  // V4-A1
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
        this.lastAliveAt = Date.now();  // V4-A1：任何入站都刷新（pong/token/progress 均算存活）
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
    // V4-A2：出站闸门只看「真未连接」，不设健康门槛
    //   （服务端跑长工具时入站静默 ≠ 连接坏，拦出站会把用户消息延迟 15s+）
    if (this.ws !== null && this.connected) {
      try {
        this.ws.send(JSON.stringify(msg));
      } catch (error) {
        console.error('WS send error: ' + error);
        this.pendingQueue.push(msg);  // 发送异常 → 入队，重连后重发（幂等键保证不重复执行）
      }
    } else {
      // WS 未连接时入队，等待重连后自动排空
      this.pendingQueue.push(msg);
      console.info('WS queued message (type=' + msg.type + '), queue length=' + this.pendingQueue.length);
    }
  }

  public sendPing(): void {
    // V4-A3：ping 永不入队（否则重连后一次性灌一批过期 ping 给服务端）
    if (this.ws !== null && this.connected) {
      try {
        this.ws.send(JSON.stringify({ type: 'ping' }));
      } catch (error) {
        // 忽略：ping 失败由看门狗的 lastAliveAt 判定处理
      }
    }
  }

  private startPing(): void {
    this.stopPing();
    this.pingTimer = setInterval(() => {
      // V4-A1：看门狗 —— 判据「sendPing() 不抛异常 + 超 WS_ALIVE_TIMEOUT 无任何入站」
      //   半开连接（切网后旧 socket 不产生 close/error）由这里兜底：强制关底层 socket，
      //   让 on('close') 走正常路径 → onDisconnect → 重连 → sync_pending 续流。
      //   ⚠️ 不调 this.close()：它会 off 掉监听 → onDisconnect 不触发 → 重连后不发 sync_pending。
      const idle: number = Date.now() - this.lastAliveAt;
      if (this.lastAliveAt > 0 && idle > WS_ALIVE_TIMEOUT) {
        console.warn('WS half-open suspected (idle=' + idle + 'ms), forcing close to reconnect');
        if (this.ws !== null) {
          try {
            this.ws.close();
          } catch (error) {
            console.error('WS force close failed: ' + error);
          }
        }
        return;
      }
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
