import { promptAction } from '@kit.ArkUI';
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { FontSize, Radius, Space, Size } from '../core/Theme.ets';
import { HermesApi } from '../utils/HermesApi.ets';
import { saveApiKey, loadApiKey, getOrCreateDeviceId, loadActiveSessionId, saveActiveSessionId } from '../utils/PreferencesHelper.ets';
// S23：本地图片/文件选择 + 上传
import { mediaPicker, PickedItem } from '../services/MediaPicker.ets';
// S2/S7：WS 事件订阅 + 协议分发下沉到 ChatWsBridge（连接控制仍在 wsService）
import { chatWsBridge, WsBridgeHooks } from '../services/ChatWsBridge.ets';
import { wsService } from '../services/WsService.ets';
// S4：消息持有与持久化下沉到 ChatService
import { chatService } from '../services/ChatService.ets';
// S3：流式状态机下沉到 core/
import { ChatStreamEngine, StreamCallbacks, STALL_TIMEOUT_NEW_SESSION } from '../core/ChatStreamEngine.ets';
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
const APP_VERSION: string = '2.11.4';

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

  /**
   * S27：顶部「Q」菜单展开状态。
   * ⚠️ 必须由页面持有：AppHeader 根容器高度只有 52px，浮层画在它里面会被裁剪
   *    （用户报"点 Q 没菜单"就是这个原因）。放到本页全屏 Stack 里渲染才显示得出来。
   */
  @State headerMenuOpen: boolean = false;

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
        { text: '取消', color: $r('app.color.text_tertiary') },
        { text: '删除', color: $r('app.color.danger') }
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

  /** S27：顶部菜单项（点完先关菜单再执行）*/
  @Builder
  HeaderMenuRow(icon: string, label: string, handler: () => void) {
    Row() {
      Text(icon).fontSize(FontSize.BODY).width(28)
      Text(label)
        .fontSize(FontSize.LABEL)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: Space.M, right: Space.M, top: 13, bottom: 13 })
    .onClick(() => {
      this.headerMenuOpen = false;
      handler();
    })
  }

  private navigateToFiles(): void {
    router.pushUrl({ url: 'pages/FilesPage' });
  }

  // ─────────────────── S21：输入栏菜单栏（图片 / 文件）───────────────────

  /**
   * 「图片」—— 选本地图片 → 上传 → 插入引用。
   *
   * ⚠️ 系统 uploadFile **不返回响应体**，所以服务端按原名存储，客户端自己拼 URL。
   */
  private async onMenuImage(): Promise<void> {
    const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
    const item: PickedItem | null = await mediaPicker.pickImage();
    if (item === null) {
      return;
    }
    this.showToast('正在上传 ' + item.name + ' …');
    const url: string = await mediaPicker.upload(ctx, item);
    if (url.length === 0) {
      this.showToast('上传失败，请检查网络后重试');
      return;
    }
    // 追加到输入框（用户可继续补充说明再发）
    const tag: string = '[图片] ' + url;
    this.inputText = this.inputText.length > 0 ? (this.inputText + '\n' + tag) : tag;
    this.showToast('已上传，可补充说明后发送');
  }

  /** 「文件」—— 选本地文件 → 上传 → 插入引用（Vault 浏览仍走 📁 图标）*/
  private async onMenuFile(): Promise<void> {
    const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
    const item: PickedItem | null = await mediaPicker.pickDocument();
    if (item === null) {
      return;
    }
    this.showToast('正在上传 ' + item.name + ' …');
    const url: string = await mediaPicker.upload(ctx, item);
    if (url.length === 0) {
      this.showToast('上传失败，请检查网络后重试');
      return;
    }
    const tag: string = '[文件] ' + url;
    this.inputText = this.inputText.length > 0 ? (this.inputText + '\n' + tag) : tag;
    this.showToast('已上传，可补充说明后发送');
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
        // S19：去重 —— 同一份回复可能已通过「拉历史」或「sync_pending 补投」进过列表，
        // 再来一次就会出现两条一模一样的回复（实测）。
        if (chatService.isLastAssistantSame(finalContent)) {
          console.info('S19 duplicate completion ignored');
        } else if (!this.replaceIndicator(finalContent)) {
          // 替换掉恢复提示（如果存在），只有没替换时才追加
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
    // 服务端确认该会话已无活跃流（也没有离线缓存）→ 结束「恢复中」，不能一直转圈
    cb.onStreamMissing = (): void => {
      this.isStreaming = false;
      this.isLoading = false;
      chatService.removeIndicator();
      this.streamContent = '';
      this.syncMessages();
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
      // 显示真实失败原因 —— 之前的固定文案「请检查 API 密钥与网络」
      // 会把 404（如授权对应的运行已不存在）误导成密钥问题
      const why: string = approveService.lastError;
      chatService.append('assistant',
        '❌ 授权提交失败：' + (why.length > 0 ? why : '未知错误'));
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
    // S12 修：会话列表页要用的 Context（切换会话后重载消息）
    this.appCtx = ctx;
    // 注：曾尝试用 @kit.NetworkKit 的 connection.on('netConnectionStateChange') 做网络监听，
    // 但该 API 在 API 24 的名字/类型已变化（connection.on / NetConnectionStateChangeInfo
    // / NetConnectionState 均不存在），编译不过。当前改用两处主动自检覆盖同样场景：
    //   1) sendMessage() 前调 ensureNetworkMatches()  —— 发消息这一刻一定自检
    //   2) onPageShow() 里已有重连分支              —— 回到前台时自检
    // 这能覆盖"切到 5G 后发消息没反应"这一实际场景。
    // 先获取固定设备 ID（用于 sync_pending 匹配离线缓存，重启后不变）
    getOrCreateDeviceId(ctx).then((deviceId: string) => {
      this.deviceId = deviceId;
      // S12：首次启动时若还没有活跃会话，默认用 deviceId 作为会话 ——
      // 兼容历史（以前 session_id 就是 device_id，老消息按 deviceId 存的）。
      // 具体选哪个会话见下方 loadActiveSessionId 块的优先级说明。
      // 启动时确定"进哪个会话"，优先级（S15）：
      //   ① 本次运行内已切过的（AppStorage）—— 冷启动时为空
      //   ② **上次退出时用的那个会话**（持久化）—— 跨重启记住用户的选择
      //   ③ 都没有（首次安装 / 清过数据）→ 回退默认的 deviceId 会话
      // ⚠️ 原先只判断 activeSessionId（内存态），重启必为空 → 每次都落到 ③，
      //    用户每次打开都被扔回那个老的 deviceId 会话（实测反馈）。
      loadActiveSessionId(ctx).then((savedSid: string) => {
        let sid: string = this.activeSessionId.length > 0 ? this.activeSessionId : savedSid;
        if (sid.length === 0) {
          sid = deviceId;
        }
        this.engine?.bindSession(sid);        // S3：把会话身份绑给状态机
        chatService.bind(ctx, sid);           // S4：消息持久化按会话分 key
        AppStorage.setOrCreate('activeSessionId', sid);
        console.info('Device ID: ' + deviceId + ' | session: ' + sid
          + (savedSid.length > 0 ? ' (restored from last used)' : ' (default)'));

        // 启动清理：上次运行遗留的「恢复中」占位符直接删掉。
        // （占位符是持久化在消息列表里的，而 pendingIndicator 是内存态重启即丢，
        //   没人再去问服务端 → 界面永久卡在"正在恢复连接"。详见 ChatService.purgeIndicators）
        chatService.loadSaved().then((): void => {
          if (chatService.purgeIndicators() > 0) {
            this.syncMessages();
          }
        });
      });
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

        // 启动自检（另见 probeStaleIndicator，onPageShow 里也会调一次）
        setTimeout((): void => { this.probeStaleIndicator(); }, 2000);

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
    // S12 修：**无条件自检一次网络**，而不是只看 isConnected()。
    // 原因：WiFi→5G 切换后那条内网 TCP 已实际断开，但客户端可能尚未收到 close
    // 事件、isConnected() 仍返回 true —— 于是不会重连，消息全进待发队列。
    // 这里先比对 baseUrl 是否与当前网络一致，不一致就重连。
    this.ensureNetworkMatches().then(() => {
      if (!wsService.isConnected()) {
        this.detectApiUrl().then((detectedUrl: string) => {
          this.setupWebSocket(detectedUrl);
          console.info('WS reconnected on foreground');
        });
      }
      // 回到前台/切回本页时也自检一次残留占位符
      setTimeout((): void => { this.probeStaleIndicator(); }, 1500);
    });
  }

  /**
   * 探测消息列表里残留的「恢复中」占位符，并设法清掉。
   *
   * ⚠️ 为什么需要：占位符是**持久化在消息列表里**的一条消息（流中断/APP 被杀时插入），
   *    而判定"要不要去问服务端"的 engine.pendingIndicator 是**内存态**，重启即丢 ——
   *    于是没人再去问，占位符永久留存（实测：会话 app-ba0fbf3a7f 一条占位符挂了很久）。
   *
   * ⚠️ 为什么不靠 WS 连接事件：`ChatWsBridge` 的 handleConnected() 只在 **WS 刚连上那一瞬**
   *    被调一次，而自检通常在它之后才跑 —— 时序上永远赶不上（实测服务端只收到 ping）。
   *    这里改成**自己直接发探测**。
   *
   * 兜底：服务端没回应（例如刚重启、offline_chats 里也没有）时，6 秒后直接把占位符删掉 ——
   * 宁可少一条提示，也不能让界面永久卡在「正在恢复连接」。
   */
  private probeStaleIndicator(): void {
    if (!chatService.hasIndicator()) {
      return;
    }
    if (!wsService.isConnected()) {
      return;   // 等连上再说，连不上就不动（避免误删）
    }
    console.info('probing stale indicator for ' + this.activeSessionId);
    this.engine?.noteStaleIndicator();
    wsService.send({
      type: 'sync_pending',
      session_id: this.activeSessionId,
      last_seq: -1
    });
    setTimeout((): void => {
      if (chatService.hasIndicator()) {
        console.info('probe got no stream -> removing stale indicator');
        chatService.removeIndicator();
        this.isStreaming = false;
        this.isLoading = false;
        this.syncMessages();
      }
    }, 6000);
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

  /**
   * S12 修（5G 切换问题）：发消息前校验当前网络与已配置的 baseUrl 是否仍匹配。
   *
   * 背景：WiFi → 5G 切换后，APP 不会重新检测网络，WS 仍粘在内网地址
   * (`ws://192.168.3.87:8866`)；5G 下该地址不可达，连接一直重试失败，
   * 消息全进 WsService 的待发队列 —— 用户看到的就是「发消息一直没反应」。
   *
   * 这里做的是「兜底自愈」：只要检测到的地址与当前不一致，就重新配置 + 重连，
   * 之后消息会随重连从待发队列里发出去（WsService.drainPendingQueue）。
   */
  private async ensureNetworkMatches(): Promise<void> {
    try {
      const detected: string = await apiConfig.detect();
      const current: string = apiConfig.getBaseUrl();
      if (current === detected) {
        return;
      }
      console.info('network changed: ' + current + ' -> ' + detected + ', reconnecting');
      this.networkMode = apiConfig.getNetworkMode();
      rest.configure(detected, apiConfig.getApiKey());
      this.hermesApi.updateConfig(detected, this.apiKey);
      wsService.close();
      this.setupWebSocket(detected);
      this.showToast('网络已切换，正在重连…');
    } catch (e) {
      console.info('ensureNetworkMatches failed: ' + this.errText(e));
    }
  }

  private async sendMessage(): Promise<void> {
    const text: string = this.inputText.trim();
    if (text === '' || this.isLoading) {
      return;
    }

    // S12 修：先确认网络与 baseUrl 仍然匹配（WiFi↔5G 切换后 WS 会粘在旧地址上）
    await this.ensureNetworkMatches();

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
    // S12 修：**新会话（activeSessionId 为空）首条消息要用更长的停滞窗口** ——
    //   新 session 的 prompt cache 是冷的（system prompt 52KB / 首轮输入约 2.7 万 token），
    //   实测首个 token 要 45-60 秒。沿用 20s 会在 token 到达前就触发续流，
    //   界面上表现为「一直恢复中」或直接被当成发送失败。
    const isNewSession: boolean = this.activeSessionId.length === 0;
    this.engine?.begin(isNewSession ? STALL_TIMEOUT_NEW_SESSION : undefined);
    if (isNewSession) {
      this.showToast('新会话首次响应需要 30-60 秒（模型要重新预热），请稍等…');
    }

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
          menuOpen: $headerMenuOpen,
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

        // 输入区域（S6：抽为 InputBar 组件；S21 加了下方菜单栏）
        InputBar({
          text: $inputText,
          loading: this.isLoading,
          onSend: () => {
            this.sendMessage();
          },
          onImage: (): void => {
            this.onMenuImage();
          },
          onFile: (): void => {
            this.onMenuFile();
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
      .backgroundColor($r('app.color.bg_card'))

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
      // ─── S27：顶部「Q」菜单浮层 ───
      // ⚠️ 画在本页全屏 Stack 里，不能画在 AppHeader 内部（后者根容器只有 52px 高会被裁掉）
      if (this.headerMenuOpen) {
        Column() {
          Column() {
            this.HeaderMenuRow('💬', '会话列表', (): void => {
              router.pushUrl({ url: 'pages/SessionsPage' });
            })
            this.HeaderMenuRow('📊', 'Token 用量', (): void => {
              router.pushUrl({ url: 'pages/TokensPage' });
            })
            this.HeaderMenuRow('📁', '知识库', (): void => {
              this.navigateToFiles();
            })
            this.HeaderMenuRow('🔔', '通知中心', (): void => {
              router.pushUrl({ url: 'pages/NotifyPage' });
            })
            this.HeaderMenuRow('⏰', '定时任务', (): void => {
              router.pushUrl({ url: 'pages/CronPage' });
            })
            this.HeaderMenuRow('⚙️', '设置', (): void => {
              this.tempApiKey = this.apiKey;
              this.showSettings = true;
            })
          }
          .width('72%')
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Radius.CARD)
          .padding({ top: Space.S, bottom: Space.S })
          .margin({ left: Space.L, top: Size.HEADER_H + Space.XS })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.Start)
        .backgroundColor($r('app.color.scrim'))
        .onClick(() => {
          this.headerMenuOpen = false;
        })
      }
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
      // 切进来的会话若残留「恢复中」占位符，也探一次（每个会话各有独立缓存，
      // 启动自检只覆盖当时那个会话，实测 app-6615... 里也挂着一条）
      setTimeout((): void => { this.probeStaleIndicator(); }, 1200);
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

  /**
   * 服务端确认了本轮会话 ID（新建会话时回执 chat_started）。
   *
   * ⚠️ 新会话有个必须处理的时序（修复前会导致「刚发的消息消失」）：
   *    1. sendMessage 时 activeSessionId 还是空 → append 的消息进了内存，
   *       但 flushNow() 开头有 `if (sessionId === '') return`，**消息没落盘**；
   *    2. 这里拿到新 ID 后写 AppStorage → 触发 @Watch('onSessionChanged')
   *       → loadSaved() 查新 key 是空的 → 转去 loadHistoryFromServer()
   *    3. 而服务端此刻还没落库那条刚发的消息 → setMessages(服务端历史)
   *       **把本地刚聊的内容整个覆盖掉** → 用户看到自己的消息没了。
   *
   *    所以必须在写 AppStorage **之前**、bind 之后立刻 flush：把内存里的消息
   *    落到新 key。这样 @Watch 触发的 loadSaved() 会命中新 key 读到正确内容，
   *    不会再去拉（还缺内容的）服务端历史。
   */
  private async onChatStartedMsg(msg: WsMessage): Promise<void> {
    const sid: string = (msg.session_id as string) ?? '';
    if (sid.length === 0 || sid === this.activeSessionId) {
      return;
    }
    if (this.activeSessionId.length === 0) {
      // 新建会话：把服务端生成的 ID 落下来
      if (this.appCtx !== null) {
        this.engine?.bindSession(sid);
        chatService.bind(this.appCtx, sid);
        // ⚠️ 关键一步：绑定新 ID 后立即把当前消息落到新 key（别等防抖，
        //    也别等 @Watch 触发重载）—— 详见方法头注释的时序说明
        await chatService.flushNowAsync();
      }
      AppStorage.setOrCreate('activeSessionId', sid);
      // S15：新建会话拿到真实 ID 后落盘 —— 否则用户"开了新会话聊完再重启"会回到旧会话
      if (this.appCtx !== null) {
        saveActiveSessionId(this.appCtx, sid).catch((e: Error) => {
          console.info('persist new session failed: ' + e.message);
        });
      }
      console.info('New session established: ' + sid
        + ' (flushed ' + chatService.getMessages().length + ' local msgs to new key)');
    }
  }
  private saveApiKeyValue(key: string): void {
    this.tempApiKey = key;
    this.saveSettings();
  }
}
