import { UIAbility } from '@kit.AbilityKit';
import { window, KeyboardAvoidMode } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
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
    // S32：键盘遮挡的**真正根因与修复**。
    //
    // 之前把 setKeyboardAvoidMode 写在 onWindowStageCreate 开头、用
    // getMainWindowSync() 拿窗口 —— 实测抛 {"code":1300002}
    // ("This window state is abnormal")，也就是**那一刻窗口还没就绪**，
    // 设置从未生效。布局怎么改都救不了。
    //
    // 正解：等 loadContent 完成（窗口已就绪）后，用**异步** getMainWindow()
    // 拿窗口再设置。同时注册键盘高度监听作为兜底观测。
    windowStage.loadContent('pages/ChatPage', (err) => {
      if (err.code) {
        hilog.error(0x0000, 'XIAOQ-KB', 'load page failed');
        return;
      }
      windowStage.getMainWindow().then((win: window.Window) => {
        try {
          // ① 键盘避让：OFFSET_WITH_CARET（=2）= 整页上移 + 跟随光标。
          //    比 OFFSET(=0) 更保守：用户反馈纯 OFFSET 时按钮仍被遮住一半。
          win.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET_WITH_CARET);
          hilog.error(0x0000, 'XIAOQ-KB', 'avoid mode OFFSET_WITH_CARET ok');
          // ② 键盘高度监听（兜底 + 便于真机诊断）
          win.on('keyboardHeightChange', (height: number) => {
            hilog.error(0x0000, 'XIAOQ-KB', 'kbHeight=' + height);
            AppStorage.setOrCreate('kbHeight', height);
          });
        } catch (e) {
          hilog.error(0x0000, 'XIAOQ-KB', 'kb setup failed: ' + JSON.stringify(e));
        }
      }).catch((e: Error) => {
        hilog.error(0x0000, 'XIAOQ-KB', 'getMainWindow failed: ' + e.message);
      });
    });
  }
}
