/**
 * InputBar —— 底部输入区
 *
 * S29 两行结构 → S30 改为「按钮内嵌」：用户反馈第二行的按钮会被键盘挡住，
 *      要求把「＋」「↑」**放进输入框内部**，＋ 在左下、↑ 在右下，
 *      并且 ↑ 做成**小圆圈气泡**的样子。
 *
 * 布局：
 *   ┌──────────────────────────────┐
 *   │  给小Q发消息...                │   ← TextArea（底部留出按钮区的高度）
 *   │  ⊕                      (↑)  │   ← 左下「＋」 / 右下「↑」气泡
 *   └──────────────────────────────┘
 *
 * ⚠️ 为什么这样能解决"键盘挡住"：
 *    原来的按钮是输入框**下面独立的一行**，键盘弹出时页面被压缩，
 *    那一行被挤到键盘下方。现在按钮是输入框内部的浮层，
 *    输入框整体（含按钮）由系统键盘避让逻辑一起上移，不会再被切掉。
 */

import { FontSize, Radius, Space, Size } from '../core/Theme.ets';

@Component
export struct InputBar {
  @Link text: string;
  @Prop loading: boolean = false;
  onSend: () => void = () => {};
  onImage: () => void = () => {};
  onFile: () => void = () => {};

  @State plusOpen: boolean = false;

  /** 「＋」菜单项 */
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
      // ─────────── 输入框（按钮内嵌其中）───────────
      Stack({ alignContent: Alignment.Bottom }) {
        // ① 输入区：底部留出 48 给按钮，避免文字被按钮压住
        TextArea({ placeholder: '给小Q发消息...', text: this.text })
          .width('100%')
          .constraintSize({ minHeight: 92, maxHeight: 150 })
          .backgroundColor(Color.Transparent)
          .padding({ left: 14, right: 14, top: 10, bottom: 50 })
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .enabled(!this.loading)
          .onChange((value: string) => {
            this.text = value;
          })

        // ② 按钮行：浮在输入框内部的底部
        Row() {
          Text('＋')
            .fontSize(20)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .width(30)
            .height(30)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(15)
            .onClick(() => {
              this.plusOpen = !this.plusOpen;
            })

          Blank()

          // ↑ 做成小圆圈气泡：有内容=主色实心，无内容=浅灰
          Text('↑')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.canSend() ? $r('app.color.text_on_brand') : $r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
            .width(30)
            .height(30)
            .backgroundColor(this.canSend() ? $r('app.color.brand') : $r('app.color.bg_card'))
            .borderRadius(15)
            .onClick(() => {
              if (this.canSend()) {
                this.onSend();
              }
            })
        }
        .width('100%')
        .padding({ left: 8, right: 8, bottom: 8 })
      }
      .width('100%')
      .backgroundColor($r('app.color.bg_input'))
      .borderRadius(Radius.CARD)

      // ─────────── 「＋」菜单（自绘浮层，向上弹出）───────────
      if (this.plusOpen) {
        Column() {
          Blank()

          Column() {
            this.PlusItem('🖼️', '添加图片', (): void => { this.onImage(); })
            this.PlusItem('📎', '添加文件', (): void => { this.onFile(); })
          }
          .width('52%')
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Radius.CARD)
          .padding({ top: 6, bottom: 6 })
          .margin({ left: 12, bottom: 152 })
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
    .padding({ left: 10, right: 10, bottom: 8, top: 6 })
    .backgroundColor($r('app.color.bg_card'))
  }

  private canSend(): boolean {
    return !this.loading && this.text.trim().length > 0;
  }
}
