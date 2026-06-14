import { promptAction } from '@kit.ArkUI';
import { router } from '@kit.ArkUI';
import { wifiManager } from '@kit.ConnectivityKit';
import { common } from '@kit.AbilityKit';
import { HermesApi, ChatMessage } from '../utils/HermesApi.ets';
import { saveApiKey, loadApiKey } from '../utils/PreferencesHelper.ets';

// 家里WiFi配置
const HOME_WIFI_SSID: string = 'HUAWEI-404';
const LOCAL_API_URL: string = 'http://192.168.3.87:8642';
const PUBLIC_API_URL: string = 'https://xiaoq.xiao-q.com';

// APP版本号（与 AppScope/app.json5 的 versionName 保持一致）
const APP_VERSION: string = '1.3.0';

@Entry
@Component
struct ChatPage {
  @State messageList: ChatMessage[] = [];
  @State inputText: string = '';
  @State isLoading: boolean = false;
  @State showSettings: boolean = false;
  @StorageLink('apiKey') apiKey: string = '';
  @State tempApiKey: string = '';
  @State networkMode: string = '检测中...';

  private hermesApi: HermesApi = new HermesApi('', '');

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

        const welcome: ChatMessage = { role: 'assistant', content: '' };
        if (this.apiKey !== '') {
          welcome.content = '你好！我是小Q v' + APP_VERSION + '，当前网络：' + this.networkMode + '。有什么可以帮你的？';
        } else {
          welcome.content = '欢迎使用小Q！请先点击右上角 ⚙️ 按钮配置API密钥。';
        }
        this.messageList.push(welcome);
      });
    });
  }

  aboutToDisappear(): void {
    this.hermesApi.destroy();
  }

  private async saveSettings(): Promise<void> {
    this.apiKey = this.tempApiKey;
    // 保存到Preferences持久化
    const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
    await saveApiKey(ctx, this.apiKey);
    // 保存时重新检测一次网络
    const detectedUrl: string = await this.detectApiUrl();
    this.hermesApi.updateConfig(detectedUrl, this.apiKey);
    this.showSettings = false;

    if (this.apiKey !== '') {
      const savedMsg: ChatMessage = { role: 'assistant', content: '配置已保存！当前网络：' + this.networkMode + '，可以开始聊天了。' };
      this.messageList.push(savedMsg);
    }
  }

  private async sendMessage(): Promise<void> {
    const text: string = this.inputText.trim();
    if (text === '' || this.isLoading) {
      return;
    }

    if (this.apiKey === '') {
      promptAction.showToast({ message: '请先配置API密钥', duration: 2000 });
      this.showSettings = true;
      return;
    }

    // 每次发送前重新检测网络（防止WiFi切换了）
    const currentUrl: string = await this.detectApiUrl();
    this.hermesApi.updateConfig(currentUrl, this.apiKey);

    const userMsg: ChatMessage = { role: 'user', content: text };
    this.messageList.push(userMsg);
    this.inputText = '';
    this.isLoading = true;

    try {
      const history: ChatMessage[] = [];
      for (let i: number = 0; i < this.messageList.length; i++) {
        history.push({
          role: this.messageList[i].role,
          content: this.messageList[i].content
        });
      }

      const reply: string = await this.hermesApi.sendMessage(history);
      const replyMsg: ChatMessage = { role: 'assistant', content: reply };
      this.messageList.push(replyMsg);
    } catch (error) {
      let errorMsg: string = '请求失败';
      if (error instanceof Error) {
        errorMsg = (error as Error).message;
      }
      const errMsg: ChatMessage = {
        role: 'assistant',
        content: '❌ 出错了：' + errorMsg + '\n\n当前网络：' + this.networkMode
      };
      this.messageList.push(errMsg);
    } finally {
      this.isLoading = false;
    }
  }

  build() {
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
          router.pushUrl({ url: 'pages/FilesPage' });
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
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor('#F8F9FF')

      // 消息列表
      List() {
        ForEach(this.messageList, (message: ChatMessage, index: number) => {
          ListItem() {
            this.MessageBubble(message)
          }
        }, (message: ChatMessage, index: number) => index.toString())
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 12, right: 12, top: 8 })

      // 输入区域
      Row() {
        TextInput({ placeholder: '给小Q发消息...', text: this.inputText })
          .layoutWeight(1)
          .height(44)
          .backgroundColor('#F0F0F5')
          .borderRadius(22)
          .padding({ left: 16, right: 16 })
          .onChange((value: string) => {
            this.inputText = value;
          })
          .onSubmit(() => {
            this.sendMessage();
          })
          .enabled(!this.isLoading)

        Button() {
          if (this.isLoading) {
            LoadingProgress()
              .width(20)
              .height(20)
              .color('#FFFFFF')
          } else {
            Text('发送')
              .fontSize(14)
              .fontColor('#FFFFFF')
          }
        }
        .width(60)
        .height(40)
        .backgroundColor(this.isLoading ? '#9999CC' : '#5B5BD6')
        .borderRadius(20)
        .margin({ left: 8 })
        .enabled(!this.isLoading && this.inputText.trim().length > 0)
        .onClick(() => {
          this.sendMessage();
        })
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 12, top: 8 })
      .backgroundColor('#FFFFFF')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F8F9FF')
    .bindContentCover(this.showSettings, this.SettingsPanel())
  }

  @Builder
  MessageBubble(message: ChatMessage) {
    Row() {
      if (message.role === 'user') {
        Blank()
      }

      Column() {
        if (message.role === 'assistant') {
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
        }

        Text(message.content)
          .fontSize(15)
          .fontColor(message.role === 'user' ? '#FFFFFF' : '#1A1A2E')
          .lineHeight(22)
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
