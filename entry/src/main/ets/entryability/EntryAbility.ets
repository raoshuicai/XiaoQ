import { UIAbility } from '@kit.AbilityKit';
import { window, KeyboardAvoidMode } from '@kit.ArkUI';
import { pushService } from '@kit.PushKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { preferences } from '@kit.ArkData';

const PUSH_REGISTER_URL: string = 'https://xiaoq.xiao-q.com';

// 模块级Preferences实例缓存，避免每次调用都创建新实例（issue #15 修复A）
let cachedPref: preferences.Preferences | null = null;

export default class EntryAbility extends UIAbility {
  private deviceId: string = '';

  onCreate(): void {
    // 异步读取或创建设备唯一ID，确保绝不频繁膨胀
    this.getOrCreateDeviceId().then((id: string) => {
      this.deviceId = id;
      // 获取并注册Push Kit令牌
      this.initPushKit();
    });
  }

  private async getOrCreateDeviceId(): Promise<string> {
    try {
      if (cachedPref === null) {
        cachedPref = await preferences.getPreferences(this.context, 'XiaoQPreferences');
      }
      let storedId = await cachedPref.get('deviceId', '') as string;
      if (storedId === '') {
        storedId = 'harmony-' + Date.now().toString() + '-' + Math.floor(Math.random() * 10000).toString();
        await cachedPref.put('deviceId', storedId);
        await cachedPref.flush();
        console.info('[PushService] Created and stored new deviceId: ' + storedId);
      } else {
        console.info('[PushService] Loaded existing deviceId: ' + storedId);
      }
      return storedId;
    } catch (err) {
      console.error('[PushService] getOrCreateDeviceId failed: ' + err);
      // Fallback: 按天取整+随机数，避免每次启动生成不同ID导致服务端设备表膨胀（issue #15 修复B）
      const todayKey = Math.floor(Date.now() / 86400000).toString();
      return 'harmony-fb-' + todayKey + '-' + Math.floor(Math.random() * 10000).toString();
    }
  }

  private initPushKit(): void {
    try {
      pushService.getToken().then((token: string) => {
        if (token !== '') {
          this.registerPushToken(token);
        }
      }).catch((error: Error) => {
        console.error('getToken failed: ' + error);
      });
    } catch (error) {
      console.error('initPushKit failed: ' + error);
    }
  }

  private async registerPushToken(token: string): Promise<void> {
    try {
      const config: rcp.SessionConfiguration = {
        baseAddress: PUSH_REGISTER_URL
      };
      const session: rcp.Session = rcp.createSession(config);
      const requestHeaders: Record<string, string> = {
        'Content-Type': 'application/json'
      };
      const bodyObj: Record<string, Object> = {
        'token': token,
        'device_id': this.deviceId
      };
      const request: rcp.Request = new rcp.Request(
        '/api/push/register',
        'POST',
        requestHeaders,
        bodyObj
      );
      const response: rcp.Response = await session.fetch(request);
      if (response.statusCode === 200) {
        console.info('Push token registered: ' + token);
      }
      session.close();
    } catch (error) {
      console.error('registerPushToken failed: ' + error);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // S31：主动把键盘避让设成 OFFSET（页面上移）。
    // ⚠️ 默认值在不同 API 版本上可能是 RESIZE（压缩布局），那样输入栏会被
    //    压到键盘下方 —— 用户反馈"输入时键盘挡住输入框"就是这个原因。
    //    OFFSET 是"整个页面上移"，输入栏始终在键盘上方可见。
    try {
      const win = windowStage.getMainWindowSync();
      win.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
      console.info('keyboard avoid mode = OFFSET');
    } catch (e) {
      console.error('setKeyboardAvoidMode failed: ' + JSON.stringify(e));
    }

    windowStage.loadContent('pages/ChatPage', (err) => {
      if (err.code) {
        console.error('load page failed');
      }
    });
  }
}
