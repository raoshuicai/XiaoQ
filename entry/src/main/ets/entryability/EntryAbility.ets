import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    // 持久化存储API Key，跨页面共享
    PersistentStorage.persistProp('apiKey', '');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/ChatPage', (err) => {
      if (err.code) {
        console.error('load page failed');
      }
    });
  }
}
