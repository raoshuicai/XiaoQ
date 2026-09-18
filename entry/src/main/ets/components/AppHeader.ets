/**
 * AppHeader —— 顶部标题栏
 *
 * S6 从 ChatPage 的 build() 内联布局抽出。
 * 两个按钮的回调由父组件注入（导航到文件页 / 打开设置面板）。
 */

@Component
export struct AppHeader {
  /** 点击 📁 → 跳文件页 */
  onFiles: () => void = () => {};
  /** 点击 📊 → 跳 Token 用量页（S8） */
  onTokens: () => void = () => {};
  /** 点击 ⚙️ → 打开设置面板 */
  onSettings: () => void = () => {};

  build() {
    Row() {
      Text('小Q')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1A1A2E')
      Blank()
      Button() {
        Text('📊')
          .fontSize(20)
      }
      .width(44)
      .height(44)
      .backgroundColor('#F0F0FF')
      .borderRadius(22)
      .margin({ right: 8 })
      .onClick(() => {
        this.onTokens();
      })
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
        this.onFiles();
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
        this.onSettings();
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor('#F8F9FF')
  }
}
