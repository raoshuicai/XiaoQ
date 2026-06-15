import { PushServiceAbility } from '@kit.PushKit';
import { WantAgent } from '@kit.WantAgentKit';

export default class XiaoQPushService extends PushServiceAbility {
  onReceiveMessage(data: string): void {
    console.info('[PushService] Received: ' + data);
    try {
      const msg: Record<string, Object> = JSON.parse(data) as Record<string, Object>;
      console.info('[PushService] Parsed: ' + JSON.stringify(msg));
    } catch (error) {
      console.error('[PushService] Parse error: ' + error);
    }
  }
}
