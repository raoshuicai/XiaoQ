import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    // Preferences持久化在ChatPage中管理，不再需要PersistentStorage
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/ChatPage', (err) => {
      if (err.code) {
        console.error('load page failed');
      }
    });
  }
}
