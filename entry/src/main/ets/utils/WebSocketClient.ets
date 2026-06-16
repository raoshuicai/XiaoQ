import { webSocket } from '@kit.NetworkKit';

const WS_PING_INTERVAL: number = 15000;  // 15秒心跳（原30秒，隧道不稳定需更快检测断线）
const WS_RECONNECT_DELAY: number = 2000; // 断线重连延时2秒（原5秒）

export interface WsMessage {
  type: string;
  // 推送/授权
  id?: string;
  title?: string;
  description?: string;
  details?: Object[];
  requester?: string;
  body?: string;
  approved?: boolean;
  timestamp?: number;
  // 流式聊天
  content?: string;       // chat_token 内容
  name?: string;          // 工具名
  arguments?: string;     // 工具参数
  message?: string;       // chat_error 信息
  // 聊天请求
  messages?: Object[];    // 消息历史
  session_id?: string;    // 会话ID
  // 授权卡片（新格式）
  run_id?: string;        // Hermes 运行ID
  command?: string;       // 需要授权的命令
  pattern_keys?: string[]; // 匹配的模式
  choices?: string[];     // 可选操作列表
}

export type WsCallback = (msg: WsMessage) => void;

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

    try {
      const fullUrl: string = this.url + '/ws/push?client_id=' + this.clientId;
      this.ws = webSocket.createWebSocket();

      this.ws.on('open', () => {
        this.connected = true;
        if (this.onConnect !== undefined) {
          this.onConnect();
        }
        this.startPing();
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
        if (this.onDisconnect !== undefined) {
          this.onDisconnect();
        }
        this.scheduleReconnect();
      });

      this.ws.on('error', () => {
        this.connected = false;
        this.stopPing();
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

  public isConnected(): boolean {
    return this.connected;
  }
}
