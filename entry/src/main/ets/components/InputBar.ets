/**
 * InputBar —— 底部输入区
 *
 * S6 从 ChatPage 的 build() 内联布局抽出。
 * S29 按用户要求改成**两行结构**（参考主流 IM）：
 *   第一行：多行输入（TextArea，可换行，最多 5 行高）
 *   第二行：左侧「＋」（点开菜单：添加图片 / 添加文件），右侧「↑」（发送）
 *
 * 设计要点：
 *   - 用 TextArea 而不是 TextInput：要支持多行输入，且初始就是两行的高度。
 *   - 「＋」的菜单是**自绘浮层**：ActionSheet / bindMenu 的对象字面量参数会被
 *     ArkTS 编译拒绝（之前踩过），自绘最稳。
 *   - 浮层定位在输入栏上方（bottom 对齐），不遮住正在输入的内容。
 */

import { FontSize, Radius, Space, Size } from '../core/Theme.ets';

@Component
export struct InputBar {
  /** 与父组件的 inputText 双向绑定 */
  @Link text: string;
  /** 请求中：发送按钮变 loading */
  @Prop loading: boolean = false;
  /** 发送回调 */
  onSend: () => void = () => {};
  /** 菜单回调 —— 图片 */
  onImage: () => void = () => {};
  /** 菜单回调 —— 文件 */
  onFile: () => void = () => {};

  /** 「＋」菜单是否展开 */
  @State plusOpen: boolean = false;

  /** 菜单项 */
  @Builder
  PlusItem(icon: string, label: string, handler: () => void) {
    Row() {
      Text(icon).fontSize(18).width(28)
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 14, right: 18, top: 13, bottom: 13 })
    .onClick(() => {
      this.plusOpen = false;
      handler();
    })
  }

  build() {
    Stack() {
      // ─────────── 输入栏本体 ───────────
      Column() {
        // 第一行：多行输入
        TextArea({ placeholder: '给小Q发消息...', text: this.text })
          .width('100%')
          .constraintSize({ minHeight: 56, maxHeight: 120 })
          .backgroundColor($r('app.color.bg_input'))
          .borderRadius(Radius.CARD)
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .enabled(!this.loading)
          .onChange((value: string) => {
            this.text = value;
          })

        // 第二行：左「＋」 右「↑」
        Row() {
          Text('＋')
            .fontSize(22)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .width(34)
            .height(34)
            .backgroundColor($r('app.color.bg_input'))
            .borderRadius(17)
            .onClick(() => {
              this.plusOpen = !this.plusOpen;
            })

          Blank()

          Text('↑')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.canSend() ? $r('app.color.text_on_brand') : $r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
            .width(34)
            .height(34)
            .backgroundColor(this.canSend() ? $r('app.color.brand') : $r('app.color.bg_input'))
            .borderRadius(17)
            .onClick(() => {
              if (this.canSend()) {
                this.onSend();
              }
            })
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 12, top: 8 })
      .backgroundColor($r('app.color.bg_card'))

      // ─────────── 「＋」菜单（自绘，bottom 对齐到输入栏上方）───────────
      if (this.plusOpen) {
        Column() {
          Blank()

          Column() {
            this.PlusItem('🖼️', '添加图片', (): void => { this.onImage(); })
            this.PlusItem('📎', '添加文件', (): void => { this.onFile(); })
          }
          .width('46%')
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Radius.CARD)
          .padding({ top: 6, bottom: 6 })
          .margin({ left: 12, bottom: 112 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.scrim'))
        .onClick(() => {
          this.plusOpen = false;
        })
      }
    }
    .width('100%')
  }

  private canSend(): boolean {
    return !this.loading && this.text.trim().length > 0;
  }
}
