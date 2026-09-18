import { promptAction } from '@kit.ArkUI';
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { HermesApi } from '../utils/HermesApi.ets';
import { saveApiKey, loadApiKey, getOrCreateDeviceId } from '../utils/PreferencesHelper.ets';
// S2/S7：WS 事件订阅 + 协议分发下沉到 ChatWsBridge（连接控制仍在 wsService）
import { chatWsBridge, WsBridgeHooks } from '../services/ChatWsBridge.ets';
import { wsService } from '../services/WsService.ets';
// S4：消息持有与持久化下沉到 ChatService
import { chatService } from '../services/ChatService.ets';
// S3：流式状态机下沉到 core/
import { ChatStreamEngine, StreamCallbacks } from '../core/ChatStreamEngine.ets';
import { systemClock } from '../core/Timers.ets';
// S1：所有共享类型统一从 models 层引入（HermesApi/PreferencesHelper/WebSocketClient 不再自行定义）
import { ChatMessage, ChatRecord } from '../models/ChatModels.ets';
import { WsMessage } from '../models/WsModels.ets';
// S5：网络检测收口到 ApiConfig
import { apiConfig } from '../core/ApiConfig.ets';
// S6：UI 组件拆出 pages（ChatPage 只负责编排）
import { AppHeader } from '../components/AppHeader.ets';
import { MessageBubble } from '../components/MessageBubble.ets';
import { StreamingBubble } from '../components/StreamingBubble.ets';
import { InputBar } from '../components/InputBar.ets';
import { ApproveLayer } from '../components/ApproveLayer.ets';
import { SettingsPanel } from '../components/SettingsPanel.ets';
// S7：审批全局化
import { approveService } from '../services/ApproveService.ets';
// S9：通知中心未读数
import { notifyService } from '../services/NotifyService.ets';

// APP版本号（与 AppScope/app.json5 的 versionName 保持一致）
const APP_VERSION: string = '2.4.2';

@Entry
@Component
struct ChatPage {
  @State messageList: ChatMessage[] = [];
  @State inputText: string = '';
  @State isLoading: boolean = false;
  @State isStreaming: boolean = false;
  @State streamContent: string = '';
  @State showSettings: boolean = false;
  @StorageLink('apiKey') apiKey: string = '';
  @State tempApiKey: string = '';
  @State networkMode: string = '检测中...';
  // S7：审批状态（showDialog/approveRunId/approveCommand/approvePatterns/
  // approveInProgress）全部移入 services/ApproveService.ets
  @State deleteMsgIndex: number = -1;

  private hermesApi: HermesApi = new HermesApi('', '');
  private deviceId: string = '';                                       // S2：设备ID（原 wsClient.clientId）
  private engine: ChatStreamEngine | null = null;   // S3：流式状态机
  private pageVisible: boolean = true;
  private listScroller: Scroller = new Scroller();

  private showToast(message: string): void {
    promptAction.showToast({ message: message });
  }

  // 自动滚动到底部
  private scrollToBottom(): void {
    setTimeout(() => {
      this.listScroller.scrollEdge(Edge.Bottom);
    }, 100);
  }

  // 确认删除消息
  private confirmDeleteMessage(): void {
    if (this.deleteMsgIndex < 0 || this.deleteMsgIndex >= this.messageList.length) {
      return;
    }
    promptAction.showDialog({
      title: '删除消息',
      message: '确定要删除这条消息吗？',
      buttons: [
        { text: '取消', color: '#999999' },
        { text: '删除', color: '#FF4444' }
      ]
    }).then((result) => {
      if (result.index === 1) {
        // S4：交给 ChatService（内部含防抖持久化）
        chatService.deleteAt(this.deleteMsgIndex);
        this.syncMessages();
        this.deleteMsgIndex = -1;
      }
    });
  }

  /** S4：把 ChatService 里的消息同步到 @State（slice 产生新数组以触发渲染） */
  private syncMessages(): void {
    this.messageList = chatService.getMessages().slice();
  }

  // 替换消息列表中最后一条恢复提示为指定内容，返回是否找到并替换
  private replaceIndicator(newContent: string): boolean {
    const replaced: boolean = chatService.replaceIndicator(newContent);
    if (replaced) {
      this.syncMessages();
    }
    return replaced;
  }

  // S3：hasIndicator / startSyncRetry / stopSyncRetry 已移入 ChatStreamEngine。
  // engine 内部用 pendingIndicator 标志代替"遍历 messageList 找占位符"的判断。

  // S4：scheduleSaveMessages / saveTimer 已下沉到 ChatService（防抖持久化在服务内）

  private navigateToFiles(): void {
    router.pushUrl({ url: 'pages/FilesPage' });
  }

  /**
   * S2：建立 WS 连接并订阅事件。
   *
   * ⚠️ 本方法会被多次调用（aboutToAppear / onPageShow / saveSettings）。
   * 每次调用前必须先注销旧订阅，否则同一消息会被处理多次 —— 这正是
   * MoA-2 #03 警告的"消息翻倍"成因。
   *
   * 处理逻辑（token 累积 / seq / 计时器 / 占位符）暂时留在本页，S3 搬进 ChatStreamEngine。
   */
  private setupWebSocket(baseUrl: string): void {
    // S7：9 个事件订阅 + 8 个协议处理方法全部收归 ChatWsBridge
    const hooks: WsBridgeHooks = new WsBridgeHooks();
    hooks.onNotification = (msg: WsMessage): void => {
      // 显示 Toast 同时，也插入到聊天框作为消息记录
      this.showToast(msg.body as string);
      chatService.append('assistant',
        '📬 ' + (msg.title !== undefined ? msg.title + '：' : '') + (msg.body as string));
      this.syncMessages();
      // S9：未读角标 +1（服务端已落库，这里只做本地即时反馈）
      notifyService.bumpUnread();
    };
    hooks.onApprove = (msg: WsMessage): void => {
      this.handleApproveRequest(msg);
    };

    // engine 用 getter 传：它由 aboutToAppear 创建，可能晚于本次 connect
    chatWsBridge.connect(baseUrl, this.deviceId,
      (): ChatStreamEngine | null => this.engine, hooks);
  }

  /** 注销全部事件订阅（重复订阅会让同一条消息被处理多次） */
  private teardownSubscriptions(): void {
    chatWsBridge.teardown();
  }

  // ────────────────────────────────────────────────────────────
  // S3：ChatStreamEngine 的回调实现 —— 页面只在这里接触状态机
  // ────────────────────────────────────────────────────────────
  private buildStreamCallbacks(): StreamCallbacks {
    // ⚠️ ArkTS 不允许用对象字面量实现接口方法集（arkts-no-untyped-obj-literals），
    //    必须 new 出实例后逐个赋值
    const cb: StreamCallbacks = new StreamCallbacks();
    cb.onStreamStart = (): void => {
      this.isStreaming = true;
    };
    cb.onContentUpdate = (full: string): void => {
      this.streamContent = full;
      this.scrollToBottom();
    };
    cb.onCompletion = (finalContent: string): void => {
      if (finalContent.length > 0) {
        // 替换掉恢复提示（如果存在），只有没替换时才追加
        if (!this.replaceIndicator(finalContent)) {
          chatService.append('assistant', finalContent);
          this.syncMessages();
        }
        this.scrollToBottom();
      }
      this.streamContent = '';
      this.isStreaming = false;
      this.isLoading = false;
    };
    cb.onFailure = (message: string): void => {
      this.isStreaming = false;
      this.isLoading = false;
      chatService.append('assistant', '❌ 出错了：' + message + '\n\n当前网络：' + this.networkMode);
      this.syncMessages();
      this.streamContent = '';
    };
    cb.onIndicator = (): void => {
      this.isLoading = false;
      chatService.append('assistant', '⏳ 正在恢复连接...当前网络：' + this.networkMode);
      this.syncMessages();
    };
    cb.onIndicatorReplace = (content: string): void => {
      this.replaceIndicator(content);
    };
    cb.onSyncNeeded = (sessionId: string, lastSeq: number): void => {
      wsService.send({
        type: 'sync_pending',
        session_id: sessionId,
        last_seq: lastSeq
      });
    };
    return cb;
  }

  private handleApproveRequest(msg: WsMessage): void {
    // S7：统一交给全局审批中心。
    // 旧格式（只带 id 的 WS 直回）已随服务端升级废弃，此处不再保留分支。
    if (msg.run_id === undefined) {
      return;
    }
    approveService.push(
      msg.run_id as string,
      (msg.command as string) ?? '',
      (msg.pattern_keys as string[]) ?? []
    );
  }

  /**
   * S7：审批提交已收归 ApproveService，本页只负责把结果写进对话流。
   * （原先这里是 respondApprove，自己持有 approveRunId 并直接调 API）
   */
  private onApproveResult(ok: boolean, choice: string): void {
    if (ok) {
      const labels: Record<string, string> = {
        'once': '仅本次放行',
        'session': '本次会话放行',
        'always': '始终允许',
        'deny': '拒绝'
      };
      const label: string = labels[choice] ?? choice;
      chatService.append('assistant', '✅ 已响应授权：' + label);
    } else {
      chatService.append('assistant',
        '❌ 授权提交失败：请检查 API 密钥与网络后重试');
    }
    this.syncMessages();
  }

  // 检测当前WiFi，返回应该使用的API地址
  // S5：检测逻辑收口到 ApiConfig（原先 ChatPage / FilesPage / FileViewPage 各有一份）
  private async detectApiUrl(): Promise<string> {
    const url: string = await apiConfig.detect();
    this.networkMode = apiConfig.getNetworkMode();   // 同步到 @State 供界面显示
    return url;
  }

  aboutToAppear(): void {
    // S3：创建流式状态机（回调实现见 buildStreamCallbacks）
    this.engine = new ChatStreamEngine(systemClock, this.buildStreamCallbacks());
    // 从Preferences加载持久化的API Key
    const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
    // 先获取固定设备 ID（用于 sync_pending 匹配离线缓存，重启后不变）
    getOrCreateDeviceId(ctx).then((deviceId: string) => {
      this.deviceId = deviceId;
      this.engine?.bindSession(deviceId);   // S3：把会话身份绑给状态机
      chatService.bind(ctx, deviceId);      // S4：消息持久化按会话分 key
      console.info('Device ID: ' + deviceId);
      return loadApiKey(ctx);
    }).then((savedKey: string) => {
      if (savedKey !== '') {
        this.apiKey = savedKey;
      }
      this.tempApiKey = this.apiKey;

      // 自动检测网络并配置（async但不await，避免阻塞启动）
      this.detectApiUrl().then((detectedUrl: string) => {
        this.hermesApi.updateConfig(detectedUrl, this.apiKey);

        // 建立WebSocket长连接
        this.setupWebSocket(detectedUrl);

        // S9：启动时同步一次未读数（服务端 DB 是单一数据源，AppStorage 只是缓存）
        notifyService.refreshUnread().catch((e: Error) => {
          console.info('unread refresh failed: ' + e.message);
        });

        // 恢复历史消息（S4：ChatService 内部处理新 key 读取 + 旧 key 迁移）
        chatService.loadSaved().then((restored: ChatMessage[]) => {
          if (restored.length > 0) {
            this.syncMessages();
            this.scrollToBottom();
          } else {
            const welcomeText: string = this.apiKey !== ''
              ? '你好！我是小Q v' + APP_VERSION + '，当前网络：' + this.networkMode + '。有什么可以帮你的？'
              : '欢迎使用小Q！请先点击右上角 ⚙️ 按钮配置API密钥。';
            chatService.append('assistant', welcomeText);
            this.syncMessages();
          }
        });
      });
    });
  }

  aboutToDisappear(): void {
    this.teardownSubscriptions();   // S2：必须注销事件订阅，否则重复订阅会让消息翻倍
    this.engine?.dispose();         // S3：状态机清掉全部计时器
    this.engine = null;
    chatService.dispose();          // S4：取消防抖计时器并立即落盘
    this.hermesApi.destroy();
    wsService.close();
  }

  /**
   * 页面从后台切回前台时，检查WebSocket状态并重连
   */
  onPageShow(): void {
    this.pageVisible = true;
    // S7：登记本页为「审批可展示页」——只有前台页面会渲染审批卡片
    approveService.setActivePage('chat');
    // S9：回到前台刷新未读数（通知页可能刚标过已读）
    notifyService.refreshUnread().catch((e: Error) => {
      console.info('unread refresh failed: ' + e.message);
    });
    // device_id 未就绪时不连接（等 aboutToAppear 的异步链），避免 pending 垃圾连接 + 连接抖动
    if (this.deviceId === '') {
      return;
    }
    if (!wsService.isConnected()) {
      // 重新检测网络并重建WebSocket
      this.detectApiUrl().then((detectedUrl: string) => {
        this.setupWebSocket(detectedUrl);
        console.info('WS reconnected on foreground');
      });
    }
  }

  /**
   * 页面推到后台时标记，但不断开WS（让系统决定是否断开）
   */
  onPageHide(): void {
    this.pageVisible = false;
    // S7：退出前台后不再渲染审批卡片（交给下一个前台页面）
    approveService.clearActivePage('chat');
  }

  private async saveSettings(): Promise<void> {
    this.apiKey = this.tempApiKey;
    // 保存到Preferences持久化
    const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
    await saveApiKey(ctx, this.apiKey);
    // 保存时重新检测一次网络
    const detectedUrl: string = await this.detectApiUrl();
    this.hermesApi.updateConfig(detectedUrl, this.apiKey);
    // 网络变化时重连WebSocket
    wsService.close();
    this.setupWebSocket(detectedUrl);
    this.showSettings = false;

    if (this.apiKey !== '') {
      chatService.append('assistant',
        '配置已保存！当前网络：' + this.networkMode + '，可以开始聊天了。');
      this.syncMessages();
    }
  }

  private sendMessage(): void {
    const text: string = this.inputText.trim();
    if (text === '' || this.isLoading) {
      return;
    }

    if (this.apiKey === '') {
      this.showToast('请先配置API密钥');
      this.showSettings = true;
      return;
    }

    // S4：历史构建（含 UI 占位符过滤）收口到 ChatService，避免各处各写一遍过滤
    const history: ChatRecord[] = chatService.buildHistoryForLlm();

    // 添加用户消息到界面
    chatService.append('user', text);
    this.syncMessages();
    this.scrollToBottom();
    history.push({ role: 'user', content: text });

    this.inputText = '';
    this.isLoading = true;
    // S3：isStreaming / streamContent / 停滞计时器 全部交给状态机
    // （原 streamStallTimer 的 20s 兜底逻辑已移入 ChatStreamEngine.begin）
    this.engine?.begin();

    // 通过WebSocket发送流式聊天请求
    wsService.send({
      type: 'chat',
      messages: history,
      session_id: this.deviceId
    });
  }
  build() {
    Stack() {
      Column() {
        // 标题栏（S6：抽为 AppHeader 组件）
        AppHeader({
          onFiles: () => {
            this.navigateToFiles();
          },
          onTokens: () => {
            router.pushUrl({ url: 'pages/TokensPage' }).catch((e: Error) => {
              this.showToast('跳转失败：' + e.message);
            });
          },
          onNotify: () => {
            router.pushUrl({ url: 'pages/NotifyPage' }).catch((e: Error) => {
              this.showToast('跳转失败：' + e.message);
            });
          },
          onCron: () => {
            router.pushUrl({ url: 'pages/CronPage' }).catch((e: Error) => {
              this.showToast('跳转失败：' + e.message);
            });
          },
          onSettings: () => {
            this.tempApiKey = this.apiKey;
            this.showSettings = true;
          }
        })

        // 消息列表
        List({ scroller: this.listScroller }) {
          ForEach(this.messageList, (message: ChatMessage, index: number) => {
            ListItem() {
              // S6：改用具名组件（原先调用 @Builder）
              MessageBubble({
                message: message,
                index: index,
                onDelete: (i: number) => {
                  this.deleteMsgIndex = i;
                  this.confirmDeleteMessage();
                }
              })
            }
          }, (message: ChatMessage, index: number) => `${index}-${message.content.length}-${message.content.substring(0, 16)}`)

          // 流式消息气泡（⚠️ @Link 绑定，@Prop 在 ListItem 内不会更新）
          ListItem() {
            StreamingBubble({ streamContent: $streamContent })
          }
          .visibility(this.isStreaming ? Visibility.Visible : Visibility.None)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 12, right: 12, top: 8 })
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        .onClick(() => {})

        // 输入区域（S6：抽为 InputBar 组件）
        InputBar({
          text: $inputText,
          loading: this.isLoading,
          onSend: () => {
            this.sendMessage();
          }
        })

        // 设置面板（S6：抽为 SettingsPanel 组件）
        if (this.showSettings) {
          SettingsPanel({
            networkMode: this.networkMode,
            apiKey: this.apiKey,
            appVersion: APP_VERSION,
            onSave: (key: string) => {
              this.saveApiKeyValue(key);
            },
            onClose: () => {
              this.showSettings = false;
            }
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F8F9FF')

      // S7：审批浮层改为全局组件（由 ApproveService 驱动）
      // 只有本页在前台时才渲染，且同一时刻只可能有一张卡片
      ApproveLayer({
        pageName: 'chat',
        onGoSettings: () => {
          this.tempApiKey = this.apiKey;
          this.showSettings = true;
        },
        onResult: (ok: boolean, choice: string) => {
          this.onApproveResult(ok, choice);
        }
      })
    }
    .width('100%')
    .height('100%')
  }

  /** S6：设置面板现在是组件，密钥由子组件回传，这里桥接到原有的保存逻辑 */
  private saveApiKeyValue(key: string): void {
    this.tempApiKey = key;
    this.saveSettings();
  }
}
