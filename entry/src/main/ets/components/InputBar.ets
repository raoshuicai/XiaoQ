/**
 * InputBar —— 底部输入区
 *
 * 版本演进：
 *   S6  从 ChatPage 的 build() 内联布局抽出
 *   S21 加菜单栏（语音/图片/文件）
 *   S22 移除语音（手机键盘自带）
 *   S29 改两行结构
 *   S30 按钮移入输入框内部（想解决键盘遮挡，但没用）
 *   S31 **最终形态**（用户指定）：
 *        - 未输入时输入框只占**一行**（minHeight 44）
 *        - 「＋」和「↑」在输入框**下面一行**
 *        - 键盘避让改为 OFFSET（在 EntryAbility 里设置，见那边的注释）
 *
 * ⚠️ 键盘遮挡的真正解法不在这个文件的布局，而在 EntryAbility 的
 *    `setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET)` —— 默认的 RESIZE 会压缩布局，
 *    把底部输入栏挤到键盘下方。布局怎么摆都救不了，得先让页面整体上移。
 */

import { FontSize, Radius, Space, Size } from '../core/Theme.ets';

@Component
export struct InputBar {
  @Link text: string;
  @Prop loading: boolean = false;
  onSend: () => void = () => {};
  onImage: () => void = () => {};
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
      // ─────────── 输入栏本体（两行）───────────
      Column() {
        // ① 输入框：未输入时只有一行高
        TextInput({ placeholder: '给小Q发消息...', text: this.text })
          .width('100%')
          // ⚠️ 用 TextInput 而不是 TextArea：TextArea 在 HarmonyOS 上有**硬编码的
          //    "最小 3 行"高度**，constraintSize.minHeight(24/44) 和显式 .height(44)
          //    都压不下来（实测始终 136~154px）。要真正一行，只能换 TextInput。
          //    代价：不支持多行输入（用户明确要求未输入时只占一行，优先满足这个）。
          .height(44)
          .backgroundColor($r('app.color.bg_input'))
          .borderRadius(Radius.CARD)
          // 只留左右 padding：上下 padding 会叠加到 height 上，导致实际高度远超 44
          .padding({ left: 14, right: 14 })
          .fontSize(FontSize.LABEL)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .enabled(!this.loading)
          .onChange((value: string) => {
            this.text = value;
          })
          .onSubmit(() => {
            if (this.canSend()) {
              this.onSend();
            }
          })

        // ② 按钮行：输入框下面一行
        Row() {
          Text('＋')
            .fontSize(20)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .width(32)
            .height(32)
            .backgroundColor($r('app.color.bg_input'))
            .borderRadius(16)
            .onClick(() => {
              this.plusOpen = !this.plusOpen;
            })

          Blank()

          // ↑ 小圆圈气泡：有内容=主色实心白箭头；空=浅灰
          Text('↑')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.canSend() ? $r('app.color.text_on_brand') : $r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
            .width(32)
            .height(32)
            .backgroundColor(this.canSend() ? $r('app.color.brand') : $r('app.color.bg_input'))
            .borderRadius(16)
            .onClick(() => {
              if (this.canSend()) {
                this.onSend();
              }
            })
        }
        .width('100%')
        .margin({ top: 6 })
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 10, top: 6 })
      .backgroundColor($r('app.color.bg_card'))

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
          .margin({ left: 12, bottom: 130 })
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
    .backgroundColor($r('app.color.bg_card'))
  }

  private canSend(): boolean {
    return !this.loading && this.text.trim().length > 0;
  }
}
