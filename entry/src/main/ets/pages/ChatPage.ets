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
// S12：会话历史（本地缓存没有时从服务端拉）
import { sessionService } from '../services/SessionService.ets';
// S5/S12：REST 客户端（拉会话历史要显式 configure）
import { rest } from '../core/HermesRest.ets';

// APP版本号（与 AppScope/app.json5 的 versionName 保持一致）
const APP_VERSION: string = '2.7.1';

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
  /**
   * S12：当前活跃会话 ID。
   * - 启动时默认填 deviceId（兼容历史：以前 session_id 就是 device_id）
   * - 在会话列表里选别的会话 -> 该值变化 -> @Watch 触发重载消息
   * - 点「新会话」-> 置空 -> 下次发消息由服务端生成并回执 chat_started
   */
  @StorageLink('activeSessionId') @Watch('onSessionChanged') activeSessionId: string = '';
  @State tempApiKey: string = '';
  @State networkMode: string = '检测中...';
  // S7：审批状态（showDialog/approveRunId/approveCommand/approvePatterns/
  // approveInProgress）全部移入 services/ApproveService.ets
  @State deleteMsgIndex: number = -1;

  private hermesApi: HermesApi = new HermesApi('', '');
  private deviceId: string = '';                                       // S2：设备ID（原 wsClient.clientId）
  /** S12：供切会话时重载消息用 */
  private appCtx: common.Context | null = null;
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
    // S12：服务端确认本轮会话（新建会话的 ID 从这里来）
    hooks.onChatStarted = (msg: WsMessage): void => {
      this.onChatStartedMsg(msg);
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
    // S11：带上触发上下文（description / session_id），卡片上能显示"哪个会话触发的"
    approveService.push(
      msg.run_id as string,
      (msg.command as string) ?? '',
      (msg.pattern_keys as string[]) ?? [],
      (msg.description as string) ?? '',
      (msg.session_id as string) ?? ''
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
  // S11 修：这里原先只调 detect()（只设 baseUrl，**不设 apiKey**），导致
  //   apiConfig.getApiKey() 长期为空 —— 而 S7 的 ApproveService 与各页面的
  //   rest.configure 都依赖它，结果审批提交的前置校验永远不过、卡片一律走
  //   「需要先配置密钥」分支。改用 ensureReady(apiKey) 把两件事一起办好。
  private async detectApiUrl(): Promise<string> {
    const url: string = await apiConfig.ensureReady(this.apiKey);
    this.networkMode = apiConfig.getNetworkMode();   // 同步到 @State 供界面显示
    return url;
  }

  aboutToAppear(): void {
    // S3：创建流式状态机（回调实现见 buildStreamCallbacks）
    this.engine = new ChatStreamEngine(systemClock, this.buildStreamCallbacks());
    // 从Preferences加载持久化的API Key
    const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
    // S11：把 Context 交给审批中心，用于加载/保存审批历史
    approveService.bind(ctx).catch((e: Error) => {
      console.info('approve history bind failed: ' + e.message);
    });
    // S12：会话列表页要用的 Context（切换会话后重载消息）
    this.appCtx = ctx;
    // 先获取固定设备 ID（用于 sync_pending 匹配离线缓存，重启后不变）
    getOrCreateDeviceId(ctx).then((deviceId: string) => {
      this.deviceId = deviceId;
      // S12：首次启动时若还没有活跃会话，默认用 deviceId 作为会话 ——
      // 兼容历史（以前 session_id 就是 device_id，老消息按 deviceId 存的）。
      // 先 bind 再写 AppStorage，避免 @Watch 触发一次多余的重载把刚恢复的消息冲掉。
      if (this.activeSessionId.length === 0) {
        this.engine?.bindSession(deviceId);   // S3：把会话身份绑给状态机
        chatService.bind(ctx, deviceId);      // S4：消息持久化按会话分 key
        AppStorage.setOrCreate('activeSessionId', deviceId);
      } else {
        this.engine?.bindSession(this.activeSessionId);
        chatService.bind(ctx, this.activeSessionId);
      }
      console.info('Device ID: ' + deviceId + ' | session: ' + this.activeSessionId);
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
            // S12：本地为空（重装 / 换设备）-> 先试服务端历史；确实没有才落欢迎语
            this.loadHistoryOrWelcome();
          }
        });
      });
    });
  }

  /** S12：本地无缓存时，先拉服务端历史；服务端也没有才显示欢迎语 */
  private async loadHistoryOrWelcome(): Promise<void> {
    const sid: string = this.activeSessionId;
    let loaded: number = 0;
    if (sid.length > 0) {
      try {
        const page = await sessionService.fetchMessages(sid, 100, 0);
        const list: ChatMessage[] = [];
        for (const m of page.items) {
          if ((m.role === 'user' || m.role === 'assistant') && m.content.trim().length > 0) {
            // ChatMessage 是 interface（不是 class），不能用 new —— 纯数据字段字面量是允许的
            list.push({ role: m.role, content: m.content });
          }
        }
        loaded = list.length;
        if (loaded > 0) {
          chatService.setMessages(list);
          console.info('Loaded ' + loaded + ' / ' + page.total + ' history for ' + sid);
        }
      } catch (e) {
        console.info('load history failed: ' + this.errText(e));
      }
    }
    if (loaded === 0) {
      const welcomeText: string = this.apiKey !== ''
        ? '你好！我是小Q v' + APP_VERSION + '，当前网络：' + this.networkMode + '。有什么可以帮你的？'
        : '欢迎使用小Q！请先点击右上角 ⚙️ 按钮配置API密钥。';
      chatService.append('assistant', welcomeText);
      this.syncMessages();
    }
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
    // S12：session_id 用「当前会话」而非 deviceId（空 = 让服务端新建）
    wsService.send({
      type: 'chat',
      messages: history,
      session_id: this.activeSessionId
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
          onSessions: () => {
            router.pushUrl({ url: 'pages/SessionsPage' }).catch((e: Error) => {
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
            },
            onHistory: () => {
              this.showSettings = false;
              router.pushUrl({ url: 'pages/ApproveHistoryPage' }).catch((e: Error) => {
                this.showToast('跳转失败：' + e.message);
              });
            },
            onModels: () => {
              this.showSettings = false;
              router.pushUrl({ url: 'pages/ModelPage' }).catch((e: Error) => {
                this.showToast('跳转失败：' + e.message);
              });
            },
            onSkills: () => {
              this.showSettings = false;
              router.pushUrl({ url: 'pages/SkillsPage' }).catch((e: Error) => {
                this.showToast('跳转失败：' + e.message);
              });
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

  /**
   * S12：会话切换回调（@StorageLink('activeSessionId') 的 @Watch）。
   *
   * ⚠️ 刻意**不重连 WebSocket** —— WS 是设备级的（client_id = device_id），
   *    会话只是它上面的一层逻辑维度。切会话重连既没必要，还会丢掉正在流的 token。
   *    真正需要隔离的是「token 落到哪个会话」：靠 engine.bindSession +
   *    chatService.bind 换掉归属，配合服务端按 session_id 回传（见决策 1）。
   */
  private onSessionChanged(): void {
    if (this.appCtx === null) {
      return;
    }
    const sid: string = this.activeSessionId;
    this.engine?.bindSession(sid);
    chatService.bind(this.appCtx, sid);
    this.streamContent = '';
    this.isStreaming = false;
    this.isLoading = false;
    chatService.loadSaved().then((restored: ChatMessage[]) => {
      if (restored.length > 0) {
        this.syncMessages();
        this.scrollToBottom();
        console.info('Switched session -> ' + (sid.length > 0 ? sid : '(new)')
          + ', restored ' + restored.length + ' from local');
      } else {
        // S12：本地没有（换过设备 / 重装 / 从没聊过）-> 去服务端拉历史
        this.loadHistoryFromServer(sid);
      }
    });
  }

  /**
   * S12：从服务端拉某个会话的历史消息。
   * 本地缓存只覆盖"本设备聊过的"，换设备或重装后要靠这里把历史补齐。
   * offset 语义是从最新往历史翻，这里先取最新一页（100 条）。
   */
  private async loadHistoryFromServer(sid: string): Promise<void> {
    if (sid.length === 0) {
      // 新会话：服务端还没有，直接清空
      chatService.setMessages([]);
      this.syncMessages();
      return;
    }
    try {
      const page = await sessionService.fetchMessages(sid, 100, 0);
      const list: ChatMessage[] = [];
      for (const m of page.items) {
        // 只显示对话双方；tool / system 消息不适合直接铺在聊天流里
        if (m.role === 'user' || m.role === 'assistant') {
          if (m.content.trim().length === 0) {
            continue;
          }
          list.push({ role: m.role, content: m.content });
        }
      }
      chatService.setMessages(list);
      this.syncMessages();
      this.scrollToBottom();
      console.info('Loaded ' + list.length + ' / ' + page.total
        + ' history messages from server for ' + sid);
      if (page.hasMore) {
        this.showToast('已加载最近 ' + list.length + ' 条（共 ' + page.total + ' 条）');
      }
    } catch (e) {
      console.info('load history failed: ' + this.errText(e));
      this.showToast('历史加载失败：' + this.errText(e));
    }
  }

  private errText(e: Object): string {
    return e instanceof Error ? (e as Error).message : String(e);
  }

  /** S12：服务端回执了本轮会话（新建会话时把生成出来的 ID 记下来）*/
  private onChatStartedMsg(msg: WsMessage): void {
    const sid: string = (msg.session_id as string) ?? '';
    if (sid.length === 0 || sid === this.activeSessionId) {
      return;
    }
    if (this.activeSessionId.length === 0) {
      // 新建会话：把服务端生成的 ID 落下来。
      // 注意先 bind 再写 AppStorage —— 写 AppStorage 会触发 @Watch，
      // 而那时 activeSessionId 已经是新值，onSessionChanged 会做一次无谓重载；
      // 这里直接同步绑定，避免刚发出的消息被重载冲掉。
      if (this.appCtx !== null) {
        this.engine?.bindSession(sid);
        chatService.bind(this.appCtx, sid);
      }
      AppStorage.setOrCreate('activeSessionId', sid);
      console.info('New session established: ' + sid);
    }
  }
  private saveApiKeyValue(key: string): void {
    this.tempApiKey = key;
    this.saveSettings();
  }
}
