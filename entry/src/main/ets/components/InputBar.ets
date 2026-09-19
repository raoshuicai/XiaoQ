/**
 * InputBar —— 底部输入区
 *
 * S32 **最终形态**（用户明确指定）：
 *   整体是一个 2 行高的容器：
 *     ┌────────────────────────────┐
 *     │  输入文本（可自动长高）        │  ← 第 1 行
 *     │  ＋                    ↑    │  ← 第 2 行：左 ＋ / 右 ↑，都是小圆气泡
 *     └────────────────────────────┘
 *
 *   输入区要能**随内容自动缩放**：输入 2 行就是 2 行高，输入 10 行就是 10 行高。
 *
 * 键盘遮挡（用户反复反馈，重点）：
 *   - EntryAbility 里已设 setKeyboardAvoidMode(OFFSET)（整页上移）
 *   - 布局上让输入栏**贴底**，避让时系统会把整页上移
 *   - ⚠️ 模拟器键盘是全屏的（实测 y=137..2856 覆盖整屏），真机是半屏，
 *     所以"避让是否生效"只能在真机确认，模拟器测不出来
 *
 * ⚠️ TextArea 高度踩坑记录（实测）：
 *   constraintSize({minHeight: 44})  -> 154px
 *   constraintSize({minHeight: 24})  -> 136px
 *   显式 .height(44)                 -> 154px
 *   去上下 padding + .height(44)     -> 154px
 *   → TextArea 有框架内定的最小高度，压不到"一行"。本版改用外层容器控 padding 再试。
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
  /** 输入区当前高度（px），由 onAreaChange 回流，用于给外层容器定高 */
  @State inputH: number = 0;

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
      // ─────────── 输入栏本体：2 行容器 ───────────
      Column() {
        // 【第 1 行】输入区：随内容自动长高（1~8 行）
        //   padding 交给外层容器，这里不设——避免 padding 叠加把最小高度顶上去
        TextArea({ placeholder: '给小Q发消息...', text: this.text })
          .width('100%')
          // maxHeight 300 ≈ 10 行字号 15 的文本，满足"输入 10 行就是 10 行高"
          .constraintSize({ minHeight: 24, maxHeight: 300 })
          // 灰色底 + 圆角（之前误用 Color.Transparent 把底色抹掉了，用户反馈"没有底色"）
          .backgroundColor($r('app.color.bg_input'))
          .borderRadius(Radius.CARD)
          // 左右留一点内边距，让文字不贴边
          .padding({ left: 12, right: 12 })
          .fontSize(FontSize.LABEL)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .enabled(!this.loading)
          .onChange((value: string) => {
            this.text = value;
          })
          .onAreaChange((_o: Area, n: Area) => {
            this.inputH = Number(n.height);
          })

        // 【第 2 行】按钮行：左 ＋ / 右 ↑，都是 32×32 小圆气泡
        Row() {
          // ＋ 气泡：浅色圆钮
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

          // ↑ 气泡：有内容=主色实心圆 + 白箭头；空=浅灰
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
        .height(36)
      }
      .width('100%')
      // 外层容器统一给 padding（内层 TextArea 不再设，避免叠加）
      // bottom 给足：键盘避让若有偏差，这点间距能兜住，避免按钮被压住一半
      .padding({ left: 12, right: 12, top: 8, bottom: 16 })
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
          .margin({ left: 12, bottom: 96 })
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
