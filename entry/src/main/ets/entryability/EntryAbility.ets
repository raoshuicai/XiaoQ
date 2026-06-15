import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { pushService } from '@kit.PushKit';
import { rcp } from '@kit.RemoteCommunicationKit';

const PUSH_REGISTER_URL: string = 'https://xiaoq.xiao-q.com';

export default class EntryAbility extends UIAbility {
  private deviceId: string = '';

  onCreate(): void {
    this.deviceId = 'harmony-' + Date.now().toString();
    // 获取并注册Push Kit令牌
    this.initPushKit();
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
    windowStage.loadContent('pages/ChatPage', (err) => {
      if (err.code) {
        console.error('load page failed');
      }
    });
  }
}
