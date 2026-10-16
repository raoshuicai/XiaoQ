import { webSocket } from '@kit.NetworkKit';
import { WsMessage, WsCallback } from '../models/WsModels.ets';

const WS_PING_INTERVAL: number = 15000;  // 15秒心跳（原30秒，隧道不稳定需更快检测断线）
const WS_RECONNECT_DELAY: number = 2000; // 断线重连延时2秒（原5秒）
// V4-A1（N5）：看门狗阈值 90s ≈ 6 个 ping 周期，对齐 ChatStreamEngine stall 下限。
//   路线一不做 create_task，长工具静默期服务端不回 pong，60s 会误重连（M-4 拦的正是这个）。
//   一切入站帧（token/progress/pong/…）都刷新 lastAliveAt → 静默期靠 chat_progress 续命。
const WS_ALIVE_TIMEOUT: number = 90000;
// V2-B：心跳伴随式探针阈值 —— 2 个心跳周期无任何入站即认为可能已切网/半开盲区，
//   此时主动解析一次地址；若变了就掐断底层 socket 走正常重连（不新增定时器）。
//   比看门狗 90s 提前 60s，且长工具静默期有 chat_progress 入站、不会误触发。
const WS_PROBE_IDLE: number = 30000;
// V2-D：重连退避上限（固定 2s 在切网抖动期会与探针互相踩踏，造成连接风暴/隧道 429）
const WS_RECONNECT_MAX: number = 16000;

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
  // V2-A：重连前解析最新地址的注入闭包。utils/ 层不得反向依赖 core/（ApiConfig），
  //   故由 services/WsService 注入；闭包内必须走 apiConfig.detect()（每次都读 SSID），
  //   不能用 ensureReady/detectApiUrl（那两个有缓存，会返回启动时的旧地址）。
  public urlResolver?: () => Promise<string>;
  // V2-C：代际号 —— 只处理"当前代际 socket"的事件，杜绝旧 socket 的 close/error
  //   触发新一轮重连（否则服务端按 client_id 顶掉旧连接时会成环）。
  private epoch: number = 0;
  // V2-D：连续失败计数（指数退避）；收到任一业务入站帧后归零。
  private retryCount: number = 0;

  constructor(clientId: string) {
    this.clientId = clientId;
  }

  public setCallbacks(onMessage: WsCallback, onConnect?: () => void, onDisconnect?: () => void): void {
    this.onMessage = onMessage;
    this.onConnect = onConnect;
    this.onDisconnect = onDisconnect;
  }

  public connect(url: string): void {
    // V2-D：显式 connect 属于「手动/用户驱动」重连 → 退避归零，立即连
    //   （否则回前台、发消息这些本应秒恢复的路径会被退避拖慢）
    this.retryCount = 0;
    this.url = url;
    void this.doConnect();
  }

  private async doConnect(): Promise<void> {
    const myEpoch: number = ++this.epoch;   // V2-C：本代际

    // V2-A：重连/首连前解析一次最新地址（网络类型可能已变）。
    //   解析必须在本代际的守卫段内 —— 若期间来了更新的一代，直接放弃本次，
    //   否则慢返回的解析结果会把新地址覆写回旧值（TOCTOU）。
    if (this.urlResolver !== undefined) {
      try {
        const resolved: string = await this.urlResolver();
        if (myEpoch !== this.epoch) {
          return;
        }
        if (resolved.length > 0 && resolved !== this.url) {
          console.info('WS url refreshed: ' + this.url + ' -> ' + resolved);
          this.url = resolved;
        }
      } catch (error) {
        console.error('WS url resolve failed: ' + error);
      }
    }
    if (myEpoch !== this.epoch) {
      return;
    }

    if (this.ws !== null) {
      this.close();
    }

    this.disconnectNotified = false;

    try {
      const fullUrl: string = this.url + '/ws/push?client_id=' + this.clientId;
      this.ws = webSocket.createWebSocket();

      this.ws.on('open', () => {
        if (myEpoch !== this.epoch) {
          return;   // V2-C：旧代际的事件，丢弃
        }
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
        if (myEpoch !== this.epoch) {
          return;   // V2-C：旧代际的事件，丢弃
        }
        this.lastAliveAt = Date.now();  // V4-A1：任何入站都刷新（pong/token/progress 均算存活）
        // V2-D：收到任何业务入站帧 = 网络确实通到了应用层（不是只握手成功）→ 退避归零。
        //   ⚠️ 刻意不在 on('open') 重置：TCP 握手成功不代表能通到服务端。
        this.retryCount = 0;
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
        if (myEpoch !== this.epoch) {
          return;   // V2-C：旧 socket 的 close（含服务端 'replaced by newer connection'）不成环
        }
        this.connected = false;
        this.stopPing();
        if (!this.disconnectNotified && this.onDisconnect !== undefined) {
          this.disconnectNotified = true;
          this.onDisconnect();
        }
        this.scheduleReconnect();
      });

      this.ws.on('error', () => {
        if (myEpoch !== this.epoch) {
          return;   // V2-C
        }
        this.connected = false;
        this.stopPing();
        if (!this.disconnectNotified && this.onDisconnect !== undefined) {
          this.disconnectNotified = true;
          this.onDisconnect();
        }
        this.scheduleReconnect();
      });

      this.ws.connect(fullUrl, (err: Error) => {
        if (myEpoch !== this.epoch) {
          return;   // V2-C
        }
        if (err !== null && err !== undefined) {
          console.error('WS connect error: ' + err + ' (url=' + this.url + ')');
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
      // V2-B：30s 无入站（2 个心跳周期）→ 可能已切网/进入半开盲区。
      //   主动解析一次地址；若已变（内网→公网）就掐断底层 socket，
      //   让 on('close') 走正常重连路径，而重连时 urlResolver 会读新地址。
      //   零新增定时器：探针生命周期与 WS 天然绑定。
      if (this.lastAliveAt > 0 && idle > WS_PROBE_IDLE) {
        void this.probeNetwork();
      }
      this.sendPing();
    }, WS_PING_INTERVAL);
  }

  /**
   * V2-B：心跳伴随式网络探针（见 startPing 的调用点）。
   * 只在地址「确实变了」时才动手，避免无谓重连。
   */
  private async probeNetwork(): Promise<void> {
    if (this.urlResolver === undefined) {
      return;
    }
    try {
      const latest: string = await this.urlResolver();
      if (latest.length > 0 && latest !== this.url) {
        console.info('WS probe: address changed ' + this.url + ' -> ' + latest + ', forcing reconnect');
        if (this.ws !== null) {
          try {
            this.ws.close();
          } catch (error) {
            console.error('WS probe close failed: ' + error);
          }
        }
      }
    } catch (error) {
      console.error('WS probe failed: ' + error);
    }
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
    // V2-D：指数退避 + ±20% 抖动。固定 2s 在切网抖动期会与探针互相踩踏，
    //   服务端 ConnectionManager 每次 connect 都顶掉旧连接 → 容易触发隧道 429。
    const base: number = Math.min(WS_RECONNECT_MAX, WS_RECONNECT_DELAY * Math.pow(2, this.retryCount));
    const jitter: number = 0.8 + Math.random() * 0.4;
    const delay: number = Math.floor(base * jitter);
    this.retryCount++;
    console.info('WS reconnect in ' + delay + 'ms (retry=' + this.retryCount + ')');
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      if (!this.connected) {
        void this.doConnect();
      }
    }, delay);
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
