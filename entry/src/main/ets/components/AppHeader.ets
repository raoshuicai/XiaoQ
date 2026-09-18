/**
 * AppHeader —— 顶部标题栏
 *
 * S6 从 ChatPage 的 build() 内联布局抽出。
 * S8 加 📊（Token 用量）。
 * S9 加 🔔（通知中心）+ 未读角标，未读数走 AppStorage 跨组件同步。
 */

import { badgeText } from '../services/NotifyService.ets';

@Component
export struct AppHeader {
  /** 点击 📊 → Token 用量页（S8） */
  onTokens: () => void = () => {};
  /** 点击 📁 → 跳文件页 */
  onFiles: () => void = () => {};
  /** 点击 🔔 → 通知中心（S9） */
  onNotify: () => void = () => {};
  /** 点击 ⚙️ → 打开设置面板 */
  onSettings: () => void = () => {};

  /**
   * 未读数。用 @StorageLink 绑 AppStorage：
   * 任何页面写 AppStorage.setOrCreate('unreadCount', n)，这里自动刷新角标。
   */
  @StorageLink('unreadCount') unreadCount: number = 0;

  @Builder
  IconButton(icon: string, handler: () => void) {
    Button() {
      Text(icon).fontSize(20)
    }
    .width(44)
    .height(44)
    .backgroundColor('#F0F0FF')
    .borderRadius(22)
    .margin({ right: 8 })
    .onClick(() => {
      handler();
    })
  }

  build() {
    Row() {
      Text('小Q')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1A1A2E')
      Blank()

      this.IconButton('📊', (): void => { this.onTokens(); })
      this.IconButton('📁', (): void => { this.onFiles(); })

      // 🔔 带未读角标（角标用 Stack 叠在右上角）
      Stack({ alignContent: Alignment.TopEnd }) {
        Button() {
          Text('🔔').fontSize(20)
        }
        .width(44)
        .height(44)
        .backgroundColor('#F0F0FF')
        .borderRadius(22)
        .onClick(() => {
          this.onNotify();
        })

        if (this.unreadCount > 0) {
          Text(badgeText(this.unreadCount))
            .fontSize(10)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Medium)
            .backgroundColor('#FF3B30')
            .borderRadius(9)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .constraintSize({ minWidth: 18 })
            .textAlign(TextAlign.Center)
            .margin({ top: -2, right: -2 })
        }
      }
      .width(44)
      .height(44)
      .margin({ right: 8 })

      this.IconButton('⚙️', (): void => { this.onSettings(); })
    }
    .width('100%')
    .padding({ left: 16, right: 8, top: 8, bottom: 8 })
    .backgroundColor('#F8F9FF')
  }
}
