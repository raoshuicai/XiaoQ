import { PushServiceAbility } from '@kit.PushKit';
import { notificationManager } from '@kit.NotificationKit';
import { WantAgent } from '@kit.WantAgentKit';

export default class XiaoQPushService extends PushServiceAbility {
  onReceiveMessage(data: string): void {
    console.info('[PushService] Received: ' + data);
    try {
      const msg: Record<string, Object> = JSON.parse(data) as Record<string, Object>;
      console.info('[PushService] Parsed: ' + JSON.stringify(msg));

      const title: string = (msg['title'] as string) ?? '小Q';
      const body: string = (msg['body'] as string) ?? (msg['alert'] as string) ?? data;

      // 发布本地通知
      this.publishNotification(title, body);
    } catch (error) {
      console.error('[PushService] Parse error: ' + error);
      // 原始数据作为通知发布
      this.publishNotification('小Q', data);
    }
  }

  private async publishNotification(title: string, body: string): Promise<void> {
    try {
      // 发布通知
      const request: notificationManager.NotificationRequest = {
        id: new Date().getTime(),
        content: {
          contentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: body
          }
        }
      };
      await notificationManager.publish(request);
      console.info('[PushService] Notification published');
    } catch (error) {
      console.error('[PushService] Publish notification failed: ' + error);
    }
  }
}
