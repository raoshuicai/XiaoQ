import { promptAction } from '@kit.ArkUI';
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { HermesApi } from '../utils/HermesApi.ets';
import { saveApiKey, loadApiKey, getOrCreateDeviceId } from '../utils/PreferencesHelper.ets';
// S2：WS 连接与事件分发下沉到 services/，页面只订阅事件
import { eventBus, Events, Unsubscribe } from '../core/EventBus.ets';
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

// APP版本号（与 AppScope/app.json5 的 versionName 保持一致）
const APP_VERSION: string = '2.0.13';

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
  @State showDialog: boolean = false;
  @State approveRunId: string = '';
  @State approveCommand: string = '';
  @State approvePatterns: string[] = [];
  @State approveInProgress: boolean = false;
  @State deleteMsgIndex: number = -1;

  private hermesApi: HermesApi = new HermesApi('', '');
  private deviceId: string = '';                                       // S2：设备ID（原 wsClient.clientId）
  private unsubs: Unsubscribe[] = [];                                  // S2：事件订阅注销句柄，必须集中管理
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
    this.teardownSubscriptions();

    // 连接由 WsService 持有；心跳/重连/待发队列仍在 WebSocketClient 内部
    wsService.connect(baseUrl, this.deviceId);

    this.unsubs.push(eventBus.on(Events.APPROVE_REQUEST,
      (m: WsMessage): void => { this.handleApproveRequest(m); }));
    this.unsubs.push(eventBus.on(Events.CHAT_SYNC_PENDING,
      (m: WsMessage): void => { this.onSyncPendingMsg(m); }));
    this.unsubs.push(eventBus.on(Events.CHAT_SYNC_RESUME,
      (m: WsMessage): void => { this.onSyncResumeMsg(m); }));
    this.unsubs.push(eventBus.on(Events.NOTIFICATION,
      (m: WsMessage): void => { this.onNotificationMsg(m); }));
    this.unsubs.push(eventBus.on(Events.CHAT_TOKEN,
      (m: WsMessage): void => { this.onChatTokenMsg(m); }));
    this.unsubs.push(eventBus.on(Events.CHAT_DONE,
      (m: WsMessage): void => { this.onChatDoneMsg(m); }));
    this.unsubs.push(eventBus.on(Events.CHAT_ERROR,
      (m: WsMessage): void => { this.onChatErrorMsg(m); }));
    this.unsubs.push(eventBus.on(Events.WS_CONNECTED,
      (): void => { this.onWsConnected(); }));
    this.unsubs.push(eventBus.on(Events.WS_DISCONNECTED,
      (): void => { this.onWsDisconnected(); }));
  }

  /** 注销全部事件订阅（重复订阅会让同一条消息被处理多次） */
  private teardownSubscriptions(): void {
    for (let i: number = 0; i < this.unsubs.length; i++) {
      this.unsubs[i]();
    }
    this.unsubs = [];
  }

  // ────────────────────────────────────────────────────────────
  // 以下 8 个方法由 S2 从原 setupWebSocket 的回调里原样抽出，
  // 处理逻辑一字未改。S3 会把它们整体搬进 core/ChatStreamEngine.ets。
  // ────────────────────────────────────────────────────────────

  /** sync_pending_response：服务端补发了离线缓存内容 */
  private onSyncPendingMsg(msg: WsMessage): void {
    const content: string = msg.content ?? '';
    if (content.length > 0) {
      this.showToast('✨ 离线数据同步成功！');
    }
    // 内容为空 → 服务器还没准备好，engine 的 retry timer 会继续重试
    this.engine?.handleSyncPending(content);
  }

  /** sync_resume：服务端通知流已恢复，后续 token 会实时推送 */
  private onSyncResumeMsg(msg: WsMessage): void {
    this.engine?.handleSyncResume(msg.caught_up ?? 0);
  }

  /** notification：服务端推送通知 */
  private onNotificationMsg(msg: WsMessage): void {
    // 显示Toast同时，也插入到聊天框作为消息记录
    this.showToast(msg.body as string);
    chatService.append('assistant',
      '📬 ' + (msg.title !== undefined ? msg.title + '：' : '') + (msg.body as string));
    this.syncMessages();
  }

  /** chat_token：流式 token 到达 */
  private onChatTokenMsg(msg: WsMessage): void {
    if (msg.content === undefined) {
      return;
    }
    this.engine?.handleToken(msg.content, msg.seq, msg.session_id ?? '');
  }

  /** chat_done：流式完成（落库与 UI 复位在 onCompletion 回调里）*/
  private onChatDoneMsg(msg: WsMessage): void {
    this.engine?.handleDone();
  }

  /** chat_error：流式失败（UI 展示在 onFailure 回调里）*/
  private onChatErrorMsg(msg: WsMessage): void {
    this.engine?.handleError(msg.message !== undefined ? msg.message : '流式回复失败');
  }

  /** WS 连上：交给 engine 判断是否需要续流 */
  private onWsConnected(): void {
    this.engine?.handleConnected();
  }

  /** WS 断开：交给 engine 决定是否插恢复占位符 */
  private onWsDisconnected(): void {
    this.engine?.handleDisconnected();
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
    // 检测新旧格式：新格式有 run_id，旧格式有 id
    if (msg.run_id !== undefined) {
      // 新格式：通过 Hermes API 授权
      this.approveRunId = msg.run_id as string;
      this.approveCommand = msg.command as string ?? '';
      this.approvePatterns = (msg.pattern_keys as string[]) ?? [];
      this.showSettings = false;
      this.showDialog = true;
      this.approveInProgress = false;
    } else {
      // 旧格式：通过 WebSocket 回复
      const reqId: string = msg.id as string;
      const reqTitle: string = msg.title as string;
      const reqDesc: string = msg.description as string;
      const reqDetails: Object[] = (msg.details as Object[]) ?? [];
      const reqRequester: string = msg.requester as string;

      // 旧格式用 promptAction 弹窗
      const respond = (approved: boolean): void => {
        const resp: WsMessage = {
          type: 'approve_response',
          id: reqId,
          approved: approved,
          timestamp: Date.now()
        };
        wsService.send(resp);
        this.showDialog = false;
        const result: string = approved ? '✅ 已授权' : '❌ 已拒绝';
        chatService.append('assistant', result);
        this.syncMessages();
      };

      promptAction.showDialog({
        title: '🔐 ' + reqTitle,
        message: reqDesc + '\n\n' + reqDetails.join('\n'),
        buttons: [
          { text: '拒绝', color: '#FF4444' },
          { text: '同意', color: '#5B5BD6' }
        ]
      }).then((result) => {
        respond(result.index === 1);
      });
    }
  }

  private async respondApprove(choice: string): Promise<void> {
    this.approveInProgress = true;
    try {
      await this.hermesApi.approveRun(this.approveRunId, choice);
      const labels: Record<string, string> = {
        'once': '仅本次放行',
        'session': '本次会话放行',
        'always': '始终允许',
        'deny': '拒绝'
      };
      const label: string = labels[choice] ?? choice;
      chatService.append('assistant', '✅ 已响应授权：' + label);
      this.syncMessages();
    } catch (error) {
      chatService.append('assistant',
        '❌ 授权请求失败：' + (error instanceof Error ? (error as Error).message : String(error)));
      this.syncMessages();
    } finally {
      this.showDialog = false;
      this.approveInProgress = false;
    }
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
    this.showDialog = false;

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
        // 标题栏
        Row() {
          Text('小Q')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A2E')
          Blank()
          Button() {
            Text('📁')
              .fontSize(20)
          }
          .width(44)
          .height(44)
          .backgroundColor('#F0F0FF')
          .borderRadius(22)
          .margin({ right: 8 })
          .onClick(() => {
            this.navigateToFiles();
          })
          Button() {
            Text('⚙️')
              .fontSize(20)
          }
          .width(44)
          .height(44)
          .backgroundColor('#F0F0FF')
          .borderRadius(22)
          .onClick(() => {
            this.tempApiKey = this.apiKey;
            this.showSettings = true;
            this.showDialog = true;
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor('#F8F9FF')

        // 消息列表
        List({ scroller: this.listScroller }) {
          ForEach(this.messageList, (message: ChatMessage, index: number) => {
            ListItem() {
              this.MessageBubble(message, index)
            }
          }, (message: ChatMessage, index: number) => `${index}-${message.content.length}-${message.content.substring(0, 16)}`)

          // 流式消息气泡
          ListItem() {
            this.StreamingBubble()
          }
          .visibility(this.isStreaming ? Visibility.Visible : Visibility.None)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 12, right: 12, top: 8 })
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        .onClick(() => {})

        // 输入区域
        Row() {
          TextInput({ placeholder: '给小Q发消息...', text: this.inputText })
            .layoutWeight(1)
            .height(44)
            .backgroundColor('#F0F0F5')
            .borderRadius(22)
            .padding({ left: 16, right: 16 })
            .onChange((value: string) => { this.inputText = value; })
            .onSubmit(() => { this.sendMessage(); })
            .enabled(!this.isLoading)

          Button() {
            if (this.isLoading) {
              LoadingProgress().width(20).height(20).color('#FFFFFF')
            } else {
              Text('发送').fontSize(14).fontColor('#FFFFFF')
            }
          }
          .width(60).height(40)
          .backgroundColor(this.isLoading ? '#9999CC' : '#5B5BD6')
          .borderRadius(20).margin({ left: 8 })
          .enabled(!this.isLoading && this.inputText.trim().length > 0)
          .onClick(() => { this.sendMessage(); })
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 12, top: 8 })
        .backgroundColor('#FFFFFF')

        // 设置面板（底部弹窗覆盖在内容之上）
        if (this.showSettings) {
          this.SettingsPanel()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F8F9FF')

      // 授权卡片覆盖层——直接用 Stack 渲染，不用 bindContentCover
      if (this.showDialog && !this.showSettings) {
        this.ApproveOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  MessageBubble(message: ChatMessage, index: number) {
    Row() {
      if (message.role === 'user') {
        Blank()
      }

      Column() {
        if (message.role === 'assistant') {
          Row() {
            Image($r('app.media.bot_avatar'))
              .width(20)
              .height(20)
              .borderRadius(10)
              .margin({ right: 6 })
            Text('小Q')
              .fontSize(12)
              .fontColor('#5B5BD6')
              .fontWeight(FontWeight.Medium)
          }
          .margin({ bottom: 4 })
        }

        Text(message.content)
          .fontSize(15)
          .fontColor(message.role === 'user' ? '#FFFFFF' : '#1A1A2E')
          .lineHeight(22)
          .copyOption(CopyOptions.LocalDevice)
      }
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor(message.role === 'user' ? '#5B5BD6' : '#FFFFFF')
      .borderRadius(16)
      .shadow({
        radius: 4,
        color: message.role === 'user' ? 'rgba(91,91,214,0.2)' : 'rgba(0,0,0,0.06)'
      })
      .constraintSize({ maxWidth: '80%' })
      .alignItems(HorizontalAlign.Start)

      if (message.role === 'assistant') {
        Blank()
      }
    }
    .width('100%')
    .margin({ top: 8, bottom: 4 })
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Top)
    .gesture(
      LongPressGesture({ repeat: false, duration: 500 })
        .onAction(() => {
          this.deleteMsgIndex = index;
          this.confirmDeleteMessage();
        })
    )
  }

  @Builder
  StreamingBubble() {
    Row() {
      Blank()

      Column() {
        Row() {
          Text('🤖')
            .fontSize(16)
            .margin({ right: 6 })
          Text('小Q')
            .fontSize(12)
            .fontColor('#5B5BD6')
            .fontWeight(FontWeight.Medium)
        }
        .margin({ bottom: 4 })

        // 流式内容：打字机效果
        Text(this.streamContent)
          .fontSize(15)
          .fontColor('#1A1A2E')
          .lineHeight(22)
          .copyOption(CopyOptions.LocalDevice)

        // 闪烁光标指示正在回复
        if (this.streamContent.length === 0) {
          Row() {
            LoadingProgress()
              .width(16)
              .height(16)
              .color('#5B5BD6')
          }
          .width('100%')
          .margin({ top: 4 })
        }
      }
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor('#FFFFFF')
      .borderRadius(16)
      .shadow({ radius: 4, color: 'rgba(0,0,0,0.06)' })
      .constraintSize({ maxWidth: '80%' })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .margin({ top: 8, bottom: 4 })
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  DialogLayer() {
    // 已废弃——改用 Stack 直接渲染 ApproveOverlay
  }

  @Builder
  ApproveOverlay() {
    Column() {
      Column() {
        // 头部
      Row() {
        Text('🔐')
          .fontSize(28)
          .margin({ right: 10 })
        Column() {
          Text('授权请求')
            .fontSize(12)
            .fontColor('#888888')
          Text('安全扫描')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A2E')
            .lineHeight(24)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .margin({ bottom: 16 })

      // 命令（代码块风格）
      if (this.approveCommand.length > 0) {
        Text('需要执行的命令：')
          .fontSize(13)
          .fontColor('#888888')
          .width('100%')
          .margin({ bottom: 6 })
        Text(this.approveCommand)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .fontFamily('Courier')
          .lineHeight(20)
          .width('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor('#1A1A2E')
          .borderRadius(8)
          .margin({ bottom: 12 })
      }

      // 匹配模式标签
      if (this.approvePatterns.length > 0) {
        Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
          ForEach(this.approvePatterns, (pattern: string) => {
            Text(pattern)
              .fontSize(11)
              .fontColor('#5B5BD6')
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor('#F0F0FF')
              .borderRadius(10)
              .margin({ right: 4, bottom: 4 })
          })
        }
        .width('100%')
        .margin({ bottom: 16 })
      }

      // 四个操作按钮
      Column() {
        Row() {
          Button() {
            Row() {
              Text('▶️').fontSize(14)
              Text('仅本次放行').fontSize(13).fontColor('#1A1A2E').margin({ left: 4 })
            }.justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1).height(44).backgroundColor('#F0F5FF').borderRadius(10).margin({ right: 6 })
          .enabled(!this.approveInProgress)
          .onClick(() => { this.respondApprove('once'); })

          Button() {
            Row() {
              Text('🔄').fontSize(14)
              Text('会话放行').fontSize(13).fontColor('#1A1A2E').margin({ left: 4 })
            }.justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1).height(44).backgroundColor('#F0FFF0').borderRadius(10).margin({ left: 6 })
          .enabled(!this.approveInProgress)
          .onClick(() => { this.respondApprove('session'); })
        }
        .width('100%')
        .margin({ bottom: 8 })

        Row() {
          Button() {
            Row() {
              Text('✅').fontSize(14)
              Text('始终允许').fontSize(13).fontColor('#FFFFFF').margin({ left: 4 })
            }.justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1).height(44).backgroundColor('#4CAF50').borderRadius(10).margin({ right: 6 })
          .enabled(!this.approveInProgress)
          .onClick(() => { this.respondApprove('always'); })

          Button() {
            Row() {
              Text('⛔').fontSize(14)
              Text('拒绝').fontSize(13).fontColor('#FFFFFF').margin({ left: 4 })
            }.justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1).height(44).backgroundColor('#FF5252').borderRadius(10).margin({ left: 6 })
          .enabled(!this.approveInProgress)
          .onClick(() => { this.respondApprove('deny'); })
        }
        .width('100%')
      }
      .width('100%')

      // 处理中
      if (this.approveInProgress) {
        Row() {
          LoadingProgress().width(16).height(16).color('#5B5BD6')
          Text('处理中...').fontSize(13).fontColor('#999999').margin({ left: 8 })
        }.width('100%').justifyContent(FlexAlign.Center).margin({ top: 12 })
      }
    }
    .width('100%')
    .padding(24)
    .backgroundColor('#FFFFFF')
    .borderRadius({ topLeft: 20, topRight: 20 })
  }
  .width('100%')
  .height('100%')
  .backgroundColor('#66000000')
  .justifyContent(FlexAlign.End)
  .onClick(() => {
    this.showDialog = false;
  })
}

  @Builder
  SettingsPanel() {
    Column() {
      // 标题
      Row() {
        Blank()
        Text('设置')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A2E')
        Blank()
        Button() {
          Text('✕')
            .fontSize(18)
            .fontColor('#999999')
        }
        .width(36)
        .height(36)
        .backgroundColor('transparent')
        .onClick(() => {
          this.showSettings = false;
          this.showDialog = false;
        })
      }
      .width('100%')
      .padding({ bottom: 20 })

      // 当前网络状态（只读提示）
      Text('当前网络')
        .fontSize(14)
        .fontColor('#666666')
        .width('100%')
        .margin({ bottom: 6 })
      Row() {
        Text(this.networkMode)
          .fontSize(14)
          .fontColor('#5B5BD6')
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .height(44)
      .backgroundColor('#F5F5FA')
      .borderRadius(10)
      .padding({ left: 12 })

      Text('在家自动走内网直连，出门自动切公网')
        .fontSize(12)
        .fontColor('#AAAAAA')
        .width('100%')
        .margin({ top: 4, bottom: 16 })

      // API 密钥
      Text('API 密钥')
        .fontSize(14)
        .fontColor('#666666')
        .width('100%')
        .margin({ bottom: 6 })
      TextInput({ placeholder: '输入Bearer Token', text: this.tempApiKey })
        .width('100%')
        .height(44)
        .backgroundColor('#F5F5FA')
        .borderRadius(10)
        .padding({ left: 12 })
        .type(InputType.Password)
        .onChange((value: string) => {
          this.tempApiKey = value;
        })

      Text('密钥在 Hermes 的 .env 文件中（API_SERVER_KEY）')
        .fontSize(12)
        .fontColor('#AAAAAA')
        .width('100%')
        .margin({ top: 8 })

      Blank()

      // 版本信息
      Text('小Q v' + APP_VERSION)
        .fontSize(12)
        .fontColor('#BBBBBB')
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 16, bottom: 4 })

      Text('由 Hermes Agent 驱动')
        .fontSize(11)
        .fontColor('#CCCCCC')
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 8 })

      // 保存按钮
      Button() {
        Text('保存')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .height(48)
      .backgroundColor('#5B5BD6')
      .borderRadius(24)
      .onClick(() => {
        this.saveSettings();
      })
    }
    .width('100%')
    .height('65%')
    .padding({ left: 24, right: 24, top: 24, bottom: 32 })
    .backgroundColor('#FFFFFF')
    .borderRadius({ topLeft: 20, topRight: 20 })
  }
}
