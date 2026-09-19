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
  /** S13：打开模型切换 */
  onModels: () => void = () => {};
  /** S13：打开技能与记忆 */
  onSkills: () => void = () => {};

  /** 编辑中的密钥（仅存于本面板） */
  @State tempKey: string = '';

  aboutToAppear(): void {
    this.tempKey = this.apiKey;
  }

  /**
   * 功能入口行（S11/S13）。做成 @Builder 复用，避免三段重复布局代码。
   * ⚠️ 回调用参数传入（在 @Builder 内部读 this.xxx 也无法解决"参数不刷新"，
   *    这里 click 回调是静态的，不需要随状态刷新，所以传参没问题）。
   */
  @Builder
  EntryRow(icon: string, hint: string, handler: () => void) {
    Row() {
      Text(icon)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Text(hint + '  ›')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .height(44)
    .padding({ left: 14, right: 14 })
    .backgroundColor($r('app.color.bg_page'))
    .borderRadius(10)
    .margin({ bottom: 6 })
    .onClick(() => {
      handler();
    })
  }

  build() {
    Column() {
      // 标题
      Row() {
        Blank()
        Text('设置')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Button() {
          Text('✕')
            .fontSize(18)
            .fontColor($r('app.color.text_tertiary'))
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
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ bottom: 6 })
      Row() {
        Text(this.networkMode)
          .fontSize(14)
          .fontColor($r('app.color.brand'))
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .height(44)
      .backgroundColor($r('app.color.bg_page'))
      .borderRadius(10)
      .padding({ left: 12 })

      Text('在家自动走内网直连，出门自动切公网')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ top: 4, bottom: 16 })

      // API 密钥
      Text('API 密钥')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ bottom: 6 })
      TextInput({ placeholder: '输入Bearer Token', text: this.tempKey })
        .width('100%')
        .height(44)
        .backgroundColor($r('app.color.bg_page'))
        .borderRadius(10)
        .padding({ left: 12 })
        .type(InputType.Password)
        .onChange((value: string) => {
          this.tempKey = value;
        })

      Text('密钥在 Hermes 的 .env 文件中（API_SERVER_KEY）')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ top: 8 })

      Blank()

      // S11/S13：功能入口
      this.EntryRow('🗂  审批历史', '最近 20 条', (): void => { this.onHistory(); })
      this.EntryRow('🧠  模型', '切换默认模型', (): void => { this.onModels(); })
      this.EntryRow('📚  技能与记忆', '浏览 Skills / MEMORY', (): void => { this.onSkills(); })

      Text('审批历史为本地记录；模型切换下次对话生效')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ bottom: 10 })

      // 版本信息
      Text('小Q v' + this.appVersion)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 16, bottom: 4 })

      Text('由 Hermes Agent 驱动')
        .fontSize(11)
        .fontColor($r('app.color.divider'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 8 })

      // 保存按钮
      Button() {
        Text('保存')
          .fontSize(16)
          .fontColor($r('app.color.text_on_brand'))
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .height(48)
      .backgroundColor($r('app.color.brand'))
      .borderRadius(24)
      .onClick(() => {
        this.onSave(this.tempKey);
      })
    }
    .width('100%')
    .height('72%')
    .padding({ left: 24, right: 24, top: 24, bottom: 32 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius({ topLeft: 20, topRight: 20 })
  }
}
