import { promptAction } from '@kit.ArkUI';
import { router } from '@kit.ArkUI';
import { wifiManager } from '@kit.ConnectivityKit';
import { common } from '@kit.AbilityKit';
import { HermesApi, ChatMessage } from '../utils/HermesApi.ets';
import { saveApiKey, loadApiKey, saveMessages, loadMessages } from '../utils/PreferencesHelper.ets';
import { StoredMessage } from '../utils/PreferencesHelper.ets';
import { WebSocketClient, WsMessage } from '../utils/WebSocketClient.ets';

// 流式聊天用的消息记录类型
interface ChatRecord {
  role: string;
  content: string;
}

// 家里WiFi配置
const HOME_WIFI_SSID: string = 'HUAWEI-404';
const LOCAL_API_URL: string = 'http://192.168.3.87:8866';
const PUBLIC_API_URL: string = 'https://xiaoq.xiao-q.com';

// APP版本号（与 AppScope/app.json5 的 versionName 保持一致）
const APP_VERSION: string = '2.0.6';

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
  private wsClient: WebSocketClient = new WebSocketClient('harmony-' + Date.now().toString());
  private saveTimer: number | undefined = undefined;
  private pageVisible: boolean = true;
  private disconnectTimeout: number | undefined = undefined;
  private lastStreamSeq: number = -1;
  private syncRetryTimer: number | undefined = undefined;
  private syncRetryCount: number = 0;
  private streamResumeTimeout: number | undefined = undefined;  // 方案D：30秒超时后重启retry
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
        this.messageList.splice(this.deleteMsgIndex, 1);
        this.messageList = [...this.messageList]; // 触发 @State 更新
        this.scheduleSaveMessages();
        this.deleteMsgIndex = -1;
      }
    });
  }

  // 替换消息列表中第一个恢复提示为指定内容
  private replaceIndicator(newContent: string): void {
    for (let i: number = this.messageList.length - 1; i >= 0; i--) {
      if (this.messageList[i].content.startsWith('⏳ 正在恢复连接...')) {
        const replaced: ChatMessage = { role: 'assistant', content: newContent };
        this.messageList.splice(i, 1, replaced);
        this.messageList = [...this.messageList]; // 触发 @State
        this.scheduleSaveMessages();
        return;
      }
    }
  }

  // 检查消息列表中是否存在恢复提示
  private hasIndicator(): boolean {
    for (let i: number = this.messageList.length - 1; i >= 0; i--) {
      if (this.messageList[i].content.startsWith('⏳ 正在恢复连接...')) {
        return true;
      }
    }
    return false;
  }

  // sync_pending 重试循环（服务器可能还在处理中）
  // force: 方案D超时兜底，跳过 hasIndicator 检查
  private startSyncRetry(force: boolean = false): void {
    this.stopSyncRetry();
    this.syncRetryCount = 0;
    this.syncRetryTimer = setInterval(() => {
      this.syncRetryCount++;
      // 每5秒重试一次，最多60秒
      if (this.syncRetryCount > 12 || (!force && !this.hasIndicator())) {
        this.stopSyncRetry();
        return;
      }
      this.wsClient.send({
        type: 'sync_pending',
        session_id: this.wsClient.clientId,
        last_seq: this.lastStreamSeq
      });
    }, 5000);
  }

  private stopSyncRetry(): void {
    if (this.syncRetryTimer !== undefined) {
      clearInterval(this.syncRetryTimer);
      this.syncRetryTimer = undefined;
    }
  }

  private scheduleSaveMessages(): void {
    if (this.saveTimer !== undefined) {
      clearTimeout(this.saveTimer);
    }
    this.saveTimer = setTimeout(() => {
      this.saveTimer = undefined;
      const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
      saveMessages(ctx, this.messageList);
    }, 500);
  }

  private navigateToFiles(): void {
    router.pushUrl({ url: 'pages/FilesPage' });
  }

  private setupWebSocket(baseUrl: string): void {
    this.wsClient.setCallbacks(
      // onMessage
      (msg: WsMessage) => {
        if (msg.type === 'approve_request') {
          this.handleApproveRequest(msg);
        } else if (msg.type === 'sync_pending_response') {
          const content: string = msg.content ?? '';
          if (content.length > 0) {
            // 旧格式：完整回复（来自 offline_chats 缓存）
            this.replaceIndicator(content);
            this.showToast('✨ 离线数据同步成功！');
          }
          // 内容为空 → 服务器还没准备好，retry timer 会继续重试
        } else if (msg.type === 'sync_resume') {
          // 方案三：服务器通知流已恢复，后续 token 将实时推送
          console.info('sync_resume: stream resumed, caught_up=' + (msg.caught_up ?? 0));
          // 如果有已累积的 streamContent，替换掉恢复提示
          if (this.streamContent.length > 0) {
            this.replaceIndicator(this.streamContent);
          }
          this.isStreaming = true; // 让 StreamingBubble 显示
          // 方案D：设30秒超时守卫生，超时后未收到chat_done则重启retry轮询
          if (this.streamResumeTimeout !== undefined) {
            clearTimeout(this.streamResumeTimeout);
          }
          this.streamResumeTimeout = setTimeout(() => {
            if (this.isStreaming) {
              console.info('streamResumeTimeout: no chat_done after 30s, starting forced retry');
              this.startSyncRetry(true);
            }
            this.streamResumeTimeout = undefined;
          }, 30000);
          // 清除断线超时
          if (this.disconnectTimeout !== undefined) {
            clearTimeout(this.disconnectTimeout);
            this.disconnectTimeout = undefined;
          }
        } else if (msg.type === 'notification') {
          // 显示Toast同时，也插入到聊天框作为消息记录
          this.showToast(msg.body as string);
          const notifyMsg: ChatMessage = {
            role: 'assistant',
            content: '📬 ' + (msg.title !== undefined ? msg.title + '：' : '') + (msg.body as string)
          };
          this.messageList.push(notifyMsg);
          this.scheduleSaveMessages();
        } else if (msg.type === 'chat_token' && msg.content !== undefined) {
          // 记录最后收到的 seq（支持断点续流）
          if (msg.seq !== undefined) {
            this.lastStreamSeq = msg.seq as number;
          }
          // 收到第一个 token 即停止 sync 重试（避免 retry 再发一次 sync 导致重复回复）
          if (this.hasIndicator()) {
            this.stopSyncRetry();
          }
          // 流式回复：过滤"思考中。。"占位符，防止泄漏到最终答复
          const token: string = msg.content;
          if (this.streamContent.length === 0 && (token === '思考中。。' || token.startsWith('思考中。。'))) {
            // 首个token如果是占位符文字，跳过
          } else {
            this.streamContent += token;
            this.streamContent = this.streamContent; // 触发 @State 更新
          }
        } else if (msg.type === 'chat_done') {
          // 流式回复完成：将流消息添加到历史记录
          if (this.streamContent.length > 0) {
            const doneMsg: ChatMessage = { role: 'assistant', content: this.streamContent };
            // 替换掉恢复提示（如果存在）
            this.replaceIndicator(this.streamContent);
            if (!this.hasIndicator()) {
              this.messageList.push(doneMsg);
            }
            this.scheduleSaveMessages();
            this.scrollToBottom();
          }
          this.streamContent = '';
          this.isStreaming = false;
          this.isLoading = false;
          this.lastStreamSeq = -1;
          this.stopSyncRetry();
          if (this.disconnectTimeout !== undefined) {
            clearTimeout(this.disconnectTimeout);
            this.disconnectTimeout = undefined;
          }
          if (this.streamResumeTimeout !== undefined) {
            clearTimeout(this.streamResumeTimeout);
            this.streamResumeTimeout = undefined;
          }
        } else if (msg.type === 'chat_error') {
          this.isStreaming = false;
          this.isLoading = false;
          if (this.streamResumeTimeout !== undefined) {
            clearTimeout(this.streamResumeTimeout);
            this.streamResumeTimeout = undefined;
          }
          const errMsg: string = (msg.message !== undefined) ? msg.message : '流式回复失败';
          const errChatMsg: ChatMessage = {
            role: 'assistant',
            content: '❌ 出错了：' + errMsg + '\n\n当前网络：' + this.networkMode
          };
          this.messageList.push(errChatMsg);
          this.scheduleSaveMessages();
          this.streamContent = '';
        }
      },
      // onConnect
      () => {
        console.info('WS connected');
        // 只对"流中断未恢复"的会话发送同步请求（避免已完成流重复回放）
        if (this.hasIndicator()) {
          this.wsClient.send({
            type: 'sync_pending',
            session_id: this.wsClient.clientId,
            last_seq: this.lastStreamSeq
          });
          this.startSyncRetry();
        }
      },
      // onDisconnect
      () => {
        console.info('WS disconnected');
        // 如果流式回复进行中断线
        if (this.isStreaming) {
          // 方案三：保持 isStreaming 状态，不清除 streamContent，以便重连后断点续流
          this.isLoading = false;
          const indicatorMsg: ChatMessage = {
            role: 'assistant',
            content: '⏳ 正在恢复连接...当前网络：' + this.networkMode
          };
          this.messageList.push(indicatorMsg);
          this.scheduleSaveMessages();
        }
      }
    );
    // 连接WebSocket（WiFi走ws://，5G走wss://）
    const wsBase: string = baseUrl.startsWith('https') ? baseUrl.replace('https', 'wss') : baseUrl.replace('http', 'ws');
    this.wsClient.connect(wsBase);
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
        this.wsClient.send(resp);
        this.showDialog = false;
        const result: string = approved ? '✅ 已授权' : '❌ 已拒绝';
        const replyMsg: ChatMessage = { role: 'assistant', content: result };
        this.messageList.push(replyMsg);
        this.scheduleSaveMessages();
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
      const replyMsg: ChatMessage = {
        role: 'assistant',
        content: '✅ 已响应授权：' + label
      };
      this.messageList.push(replyMsg);
      this.scheduleSaveMessages();
    } catch (error) {
      const errMsg: ChatMessage = {
        role: 'assistant',
        content: '❌ 授权请求失败：' + (error instanceof Error ? (error as Error).message : String(error))
      };
      this.messageList.push(errMsg);
      this.scheduleSaveMessages();
    } finally {
      this.showDialog = false;
      this.approveInProgress = false;
    }
  }

  // 检测当前WiFi，返回应该使用的API地址
  private async detectApiUrl(): Promise<string> {
    try {
      const linkedInfo: wifiManager.WifiLinkedInfo = await wifiManager.getLinkedInfo();
      const currentSsid: string = linkedInfo.ssid;
      if (currentSsid === HOME_WIFI_SSID) {
        this.networkMode = '🏠 本地网络';
        return LOCAL_API_URL;
      }
      this.networkMode = '🌐 公网 (' + currentSsid + ')';
      return PUBLIC_API_URL;
    } catch (error) {
      // 没有WiFi连接或获取失败，走公网
      this.networkMode = '🌐 公网';
      return PUBLIC_API_URL;
    }
  }

  aboutToAppear(): void {
    // 从Preferences加载持久化的API Key
    const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
    loadApiKey(ctx).then((savedKey: string) => {
      if (savedKey !== '') {
        this.apiKey = savedKey;
      }
      this.tempApiKey = this.apiKey;

      // 自动检测网络并配置（async但不await，避免阻塞启动）
      this.detectApiUrl().then((detectedUrl: string) => {
        this.hermesApi.updateConfig(detectedUrl, this.apiKey);

        // 建立WebSocket长连接
        this.setupWebSocket(detectedUrl);

        // 恢复历史消息
        loadMessages(ctx).then((saved: StoredMessage[]) => {
          if (saved.length > 0) {
            const restored: ChatMessage[] = [];
            for (let i: number = 0; i < saved.length; i++) {
              restored.push({ role: saved[i].role, content: saved[i].content });
            }
            this.messageList = restored;
            this.scrollToBottom();
          } else {
            const welcome: ChatMessage = { role: 'assistant', content: '' };
            if (this.apiKey !== '') {
              welcome.content = '你好！我是小Q v' + APP_VERSION + '，当前网络：' + this.networkMode + '。有什么可以帮你的？';
            } else {
              welcome.content = '欢迎使用小Q！请先点击右上角 ⚙️ 按钮配置API密钥。';
            }
            this.messageList.push(welcome);
          }
        });
      });
    });
  }

  aboutToDisappear(): void {
    this.hermesApi.destroy();
    this.wsClient.close();
    if (this.disconnectTimeout !== undefined) {
      clearTimeout(this.disconnectTimeout);
      this.disconnectTimeout = undefined;
    }
    if (this.streamResumeTimeout !== undefined) {
      clearTimeout(this.streamResumeTimeout);
      this.streamResumeTimeout = undefined;
    }
    this.stopSyncRetry();
  }

  /**
   * 页面从后台切回前台时，检查WebSocket状态并重连
   */
  onPageShow(): void {
    this.pageVisible = true;
    if (!this.wsClient.isConnected()) {
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
    this.wsClient.close();
    this.setupWebSocket(detectedUrl);
    this.showSettings = false;
    this.showDialog = false;

    if (this.apiKey !== '') {
      const savedMsg: ChatMessage = { role: 'assistant', content: '配置已保存！当前网络：' + this.networkMode + '，可以开始聊天了。' };
      this.messageList.push(savedMsg);
      this.scheduleSaveMessages();
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

    // 先构建历史消息（不含当前未完成的流消息）
    const history: ChatRecord[] = [];
    for (let i: number = 0; i < this.messageList.length; i++) {
      const m: ChatMessage = this.messageList[i];
      history.push({ role: m.role, content: m.content });
    }

    // 添加用户消息到界面
    const userMsg: ChatMessage = { role: 'user', content: text };
    this.messageList.push(userMsg);
    this.scheduleSaveMessages();
    this.scrollToBottom();
    history.push({ role: 'user', content: text });

    this.inputText = '';
    this.isLoading = true;
    this.isStreaming = true;
    this.streamContent = '';

    // 通过WebSocket发送流式聊天请求
    this.wsClient.send({
      type: 'chat',
      messages: history,
      session_id: this.wsClient.clientId
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
          }, (message: ChatMessage, index: number) => index.toString())

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
