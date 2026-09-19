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
  /** 点击 ⏰ → 定时任务面板（S10） */
  onCron: () => void = () => {};
  /** S12：点标题 → 打开会话列表 */
  onSessions: () => void = () => {};
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
    .width(42)
    .height(42)
    .backgroundColor('#F0F0FF')
    .borderRadius(21)
    .margin({ right: 6 })
    .onClick(() => {
      handler();
    })
  }

  build() {
    Row() {
      Text('小Q')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1A1A2E')
        .padding({ left: 2, right: 6, top: 4, bottom: 4 })
        .onClick(() => {
          // 标题也可点（保留这个入口，但不再依赖它 —— 顶部有显式的 💬 按钮）
          this.onSessions();
        })
      Blank()

      // S12 修正：会话入口做成显式按钮。
      // 原先只挂"点标题"，没有任何视觉提示 —— 用户根本不知道那里能点。
      // 💬 放在最前面：切会话是最高频的操作。
      this.IconButton('💬', (): void => { this.onSessions(); })
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

      this.IconButton('⏰', (): void => { this.onCron(); })
      this.IconButton('⚙️', (): void => { this.onSettings(); })
    }
    .width('100%')
    .padding({ left: 16, right: 8, top: 8, bottom: 8 })
    .backgroundColor('#F8F9FF')
  }
}
