/**
 * InputBar —— 底部输入区
 *
 * S34 **最终形态** —— 关键洞察：
 *
 * 系统的键盘避让（KeyboardAvoidMode）参照物是**输入框组件本身**（TextArea），
 * 它只保证"输入框可见"，**不会管输入框下面的东西**。
 * 所以如果 ＋/↑ 排成独立的第二行（在 TextArea 之外），避让后必然是
 * "输入框露出、按钮行被键盘盖住" —— 这就是用户反复反馈的"遮一半"。
 *
 * 正解：把按钮行放进 **TextArea 的范围之内**（用 TextArea 的 padding.bottom
 * 留出按钮高度的空间，按钮用 Stack 浮在那块区域底部）。
 * 视觉上仍是「第一行输入、第二行 ＋/↑」，但结构上属于输入框 →
 * 整个输入栏成为一个避让单元，键盘弹起时一起露出。
 *
 * 布局：
 *   ┌────────────────────────────┐  ← TextArea（含底部 padding）
 *   │  输入文本...                 │
 *   │  ⊕                    (↑)  │  ← 浮在 TextArea 底部 padding 区
 *   └────────────────────────────┘
 *
 * 另：EntryAbility 已设 KeyboardAvoidMode.RESIZE（与根容器 height('100%') 自洽）。
 */

import { FontSize, Radius, Space, Size } from '../core/Theme.ets';

/** 按钮行高度（px）—— TextArea 的底部 padding 必须 ≥ 它，否则按钮会被文字压住 */
const ACTION_ROW_H: number = 40;

@Component
export struct InputBar {
  @Link text: string;
  @Prop loading: boolean = false;
  /** S43：YOLO 是否已开启（会话级跳过危险命令审批） */
  @Prop yoloOn: boolean = false;
  onSend: () => void = () => {};
  /** S43：点击 Y 气泡 —— 切换 YOLO */
  onToggleYolo: () => void = () => {};
  onImage: () => void = () => {};
  onFile: () => void = () => {};

  @State plusOpen: boolean = false;

  @Builder
  PlusItem(icon: string, label: string, handler: () => void) {
    Row() {
      Text(icon).fontSize(18).width(28)
      Text(label)
        .fontSize(FontSize.LABEL)
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
        // 输入框 + 按钮**同属一个 Stack**：按钮浮在输入框内部底部区域，
        // 这样键盘避让会把它俩当成一个整体。
        Stack({ alignContent: Alignment.Bottom }) {
          TextArea({ placeholder: '给小Q发消息...', text: this.text })
            .width('100%')
            .constraintSize({ minHeight: 24, maxHeight: 300 })
            .backgroundColor($r('app.color.bg_input'))
            .borderRadius(Radius.CARD)
            .fontSize(FontSize.LABEL)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .enabled(!this.loading)
            // ⚠️ 底部 padding 必须 ≥ 按钮行高度：把按钮行的空间"算进"输入框内部，
            //    键盘避让才会连按钮一起保证可见（这是修掉"遮一半"的关键）
            .padding({ left: 14, right: 14, top: 10, bottom: ACTION_ROW_H + 6 })
            .onChange((value: string) => {
              this.text = value;
            })

          // 按钮行：浮在输入框底部（视觉上是"第二行"）
          Row() {
            Text('＋')
              .fontSize(20)
              // 用户要求：默认纯黑字（白底黑字）
              .fontColor($r('app.color.btn_circle_fg'))
              .textAlign(TextAlign.Center)
              .width(32)
              .height(32)
              .backgroundColor($r('app.color.btn_circle_bg'))
              .borderRadius(16)
              .onClick(() => {
                this.plusOpen = !this.plusOpen;
              })

            // ─────── S43：「Y」YOLO 气泡（在 ＋ 右侧）───────
            // 默认白底 + 黑 Y；开启后主题色底 + 白 Y（与 ↑ 的配色规则一致）
            Text('Y')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.yoloOn ? $r('app.color.text_on_brand') : $r('app.color.btn_circle_fg'))
              .textAlign(TextAlign.Center)
              .width(32)
              .height(32)
              .backgroundColor(this.yoloOn ? $r('app.color.brand') : $r('app.color.btn_circle_bg'))
              .borderRadius(16)
              .margin({ left: 8 })
              .onClick(() => {
                this.onToggleYolo();
              })

            Blank()

            Text('↑')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              // 用户要求：默认纯黑字；有输入时整圈变主题色 #4F46E5 且**字保持白**
              .fontColor(this.canSend() ? $r('app.color.text_on_brand') : $r('app.color.btn_circle_fg'))
              .textAlign(TextAlign.Center)
              .width(32)
              .height(32)
              .backgroundColor(this.canSend() ? $r('app.color.brand') : $r('app.color.btn_circle_bg'))
              .borderRadius(16)
              .onClick(() => {
                if (this.canSend()) {
                  this.onSend();
                }
              })
          }
          .width('100%')
          .height(ACTION_ROW_H)
          .padding({ left: 10, right: 10 })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.bg_card'))

      // ─────────── 「＋」菜单 ───────────
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
          .margin({ left: 12, bottom: 110 })
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
