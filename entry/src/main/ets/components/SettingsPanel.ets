/**
 * SettingsPanel —— 设置面板（底部弹层）
 *
 * S6 从 ChatPage 的 @Builder 提升为独立 @Component。
 *
 * 状态归属变化：原先 tempApiKey 是父组件的 @State（因为 @Builder 不能有独立状态），
 * 现在提升为组件后改为本组件内部的 @State —— 编辑中的明文只在面板内部存在，
 * 只有点「保存」才通过 onSave 回传给父组件落盘。
 *
 * ⚠️ 安全：apiKey 是凭据。本组件只负责「把用户输入原样回传」，
 * 不做任何打印/日志，父组件也不回显真实密钥。
 */

@Component
export struct SettingsPanel {
  /** 当前网络模式（只读展示） */
  @Prop networkMode: string = '';
  /** 已保存的密钥（用于初始化输入框） */
  @Prop apiKey: string = '';
  /** 版本号 */
  @Prop appVersion: string = '';
  /** 保存回调（把用户输入的密钥交给父组件） */
  onSave: (key: string) => void = () => {};
  /** 关闭回调 */
  onClose: () => void = () => {};
  /** S11：打开审批历史 */
  onHistory: () => void = () => {};

  /** 编辑中的密钥（仅存于本面板） */
  @State tempKey: string = '';

  aboutToAppear(): void {
    this.tempKey = this.apiKey;
  }

  build() {
    Column() {
      // 标题
      Row() {
        Blank()
        Text('设置')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A2E')
        Blank()
        Button() {
          Text('✕')
            .fontSize(18)
            .fontColor('#999999')
        }
        .width(36)
        .height(36)
        .backgroundColor('transparent')
        .onClick(() => {
          this.onClose();
        })
      }
      .width('100%')
      .padding({ bottom: 20 })

      // 当前网络状态（只读提示）
      Text('当前网络')
        .fontSize(14)
        .fontColor('#666666')
        .width('100%')
        .margin({ bottom: 6 })
      Row() {
        Text(this.networkMode)
          .fontSize(14)
          .fontColor('#5B5BD6')
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .height(44)
      .backgroundColor('#F5F5FA')
      .borderRadius(10)
      .padding({ left: 12 })

      Text('在家自动走内网直连，出门自动切公网')
        .fontSize(12)
        .fontColor('#AAAAAA')
        .width('100%')
        .margin({ top: 4, bottom: 16 })

      // API 密钥
      Text('API 密钥')
        .fontSize(14)
        .fontColor('#666666')
        .width('100%')
        .margin({ bottom: 6 })
      TextInput({ placeholder: '输入Bearer Token', text: this.tempKey })
        .width('100%')
        .height(44)
        .backgroundColor('#F5F5FA')
        .borderRadius(10)
        .padding({ left: 12 })
        .type(InputType.Password)
        .onChange((value: string) => {
          this.tempKey = value;
        })

      Text('密钥在 Hermes 的 .env 文件中（API_SERVER_KEY）')
        .fontSize(12)
        .fontColor('#AAAAAA')
        .width('100%')
        .margin({ top: 8 })

      Blank()

      // S11：审批历史入口
      Row() {
        Text('🗂  审批历史')
          .fontSize(14)
          .fontColor('#1A1A2E')
          .layoutWeight(1)
        Text('最近 20 条  ›')
          .fontSize(12)
          .fontColor('#AAAAAA')
      }
      .width('100%')
      .height(46)
      .padding({ left: 14, right: 14 })
      .backgroundColor('#F5F5FA')
      .borderRadius(10)
      .margin({ bottom: 6 })
      .onClick(() => {
        this.onHistory();
      })

      Text('审批是本地记录，答过/关掉的都会留痕')
        .fontSize(11)
        .fontColor('#AAAAAA')
        .width('100%')
        .margin({ bottom: 10 })

      // 版本信息
      Text('小Q v' + this.appVersion)
        .fontSize(12)
        .fontColor('#BBBBBB')
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 16, bottom: 4 })

      Text('由 Hermes Agent 驱动')
        .fontSize(11)
        .fontColor('#CCCCCC')
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 8 })

      // 保存按钮
      Button() {
        Text('保存')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .height(48)
      .backgroundColor('#5B5BD6')
      .borderRadius(24)
      .onClick(() => {
        this.onSave(this.tempKey);
      })
    }
    .width('100%')
    .height('65%')
    .padding({ left: 24, right: 24, top: 24, bottom: 32 })
    .backgroundColor('#FFFFFF')
    .borderRadius({ topLeft: 20, topRight: 20 })
  }
}
