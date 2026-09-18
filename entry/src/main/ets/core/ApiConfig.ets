/**
 * ApiConfig —— 网络环境检测与 API 凭据持有
 *
 * S5 引入。从 ChatPage 收口两件事：
 *   1. `detectApiUrl()`：按 WiFi SSID 判定走内网直连还是公网隧道
 *   2. apiKey / baseUrl 的持有与变更通知
 *
 * 为什么需要：这两件事原先散在 ChatPage，且 FileApi / HermesApi 各自再存一份
 * baseUrl + apiKey。现在只有一份真相源，变更时统一广播，
 * 由 HermesRest 重建连接、页面更新显示。
 *
 * 分层约束：本文件属于 core/，不得 import 任何 ArkUI 或页面。
 */

import { wifiManager } from '@kit.ConnectivityKit';

/** 家里 WiFi 的 SSID —— 匹配时走内网直连 */
const HOME_WIFI_SSID: string = 'HUAWEI-404';
/** 内网直连地址（WSL 服务所在的 Windows 主机） */
const LOCAL_API_URL: string = 'http://192.168.3.87:8866';
/** 公网入口（Cloudflare 隧道） */
const PUBLIC_API_URL: string = 'https://xiaoq.xiao-q.com';

export type ConfigListener = (baseUrl: string, apiKey: string, networkMode: string) => void;

export class ApiConfig {
  private baseUrl: string = '';
  private apiKey: string = '';
  private networkMode: string = '检测中...';
  private listeners: ConfigListener[] = [];

  /**
   * 检测当前网络，返回应使用的 baseUrl。
   * 家里 WiFi → 内网直连；其它（含 5G / 无 WiFi）→ 公网隧道。
   */
  public async detect(): Promise<string> {
    try {
      const linkedInfo: wifiManager.WifiLinkedInfo = await wifiManager.getLinkedInfo();
      const currentSsid: string = linkedInfo.ssid;
      if (currentSsid === HOME_WIFI_SSID) {
        this.networkMode = '🏠 本地网络';
        this.baseUrl = LOCAL_API_URL;
        return this.baseUrl;
      }
      this.networkMode = '🌐 公网 (' + currentSsid + ')';
      this.baseUrl = PUBLIC_API_URL;
      return this.baseUrl;
    } catch (error) {
      // 没有 WiFi 连接或获取失败，走公网
      this.networkMode = '🌐 公网';
      this.baseUrl = PUBLIC_API_URL;
      return this.baseUrl;
    }
  }

  public getBaseUrl(): string {
    return this.baseUrl;
  }

  public getApiKey(): string {
    return this.apiKey;
  }

  /**
   * 确保已完成配置，返回 baseUrl（供页面在 aboutToAppear 里一行调用）。
   * 幂等：已检测过就不重复检测；apiKey 有变化则更新。
   */
  public async ensureReady(apiKey: string): Promise<string> {
    if (this.baseUrl === '') {
      await this.detect();
    }
    if (apiKey !== '' && apiKey !== this.apiKey) {
      this.apiKey = apiKey;
    }
    return this.baseUrl;
  }

  public getNetworkMode(): string {
    return this.networkMode;
  }

  public isConfigured(): boolean {
    return this.baseUrl !== '' && this.apiKey !== '';
  }

  /** 更新 apiKey 并广播（保存设置时调用） */
  public setApiKey(key: string): void {
    this.apiKey = key;
    this.notify();
  }

  public registerListener(cb: ConfigListener): void {
    this.listeners.push(cb);
  }

  private notify(): void {
    for (let i: number = 0; i < this.listeners.length; i++) {
      try {
        this.listeners[i](this.baseUrl, this.apiKey, this.networkMode);
      } catch (e) {
        console.error('ApiConfig listener error: ' + e);
      }
    }
  }
}

export const apiConfig: ApiConfig = new ApiConfig();
