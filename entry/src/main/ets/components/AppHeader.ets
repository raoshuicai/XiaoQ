/**
 * AppHeader —— 顶部标题栏
 *
 * S6 从 ChatPage 的 build() 内联布局抽出。S8 加 Token 用量，S9 加通知 + 未读角标。
 * S26 视觉改造：左上角改成一个圆形「Q」（浅色底 + 主色字，参考 Kimi），
 *     6 个入口收进它的点击菜单；颜色全部走 $r('app.color.xxx')。
 * S28 标题居中：改用 Stack —— 标题全宽居中，左右控件浮在上层。
 *
 * ⚠️ 为什么标题不用 Row + layoutWeight 居中：
 *    Row 里两侧控件的**实际占位**不等宽（Text('Q') 自带约 40px 内边距，
 *    而右侧 Stack 是精确 32px），标题框中心必然偏（实测偏右 20px）。
 *    Stack 方案下标题是"全宽 + textAlign: Center"，与两侧控件宽度无关，绝对居中。
 *
 * ⚠️ 菜单浮层**不在这里渲染**：本组件根容器高度只有 HEADER_H(52px)，
 *    浮层画在内部会被裁剪成 52px 高（用户报"点 Q 没菜单"就是这个原因）。
 *    这里只改 menuOpen 状态，浮层由 ChatPage 的全屏 Stack 渲染。
 */

import { badgeText } from '../services/NotifyService.ets';
import { FontSize, Radius, Space, Size } from '../core/Theme.ets';

@Component
export struct AppHeader {
  @Prop title: string = '小Q';
  onTokens: () => void = () => {};
  onFiles: () => void = () => {};
  onNotify: () => void = () => {};
  onCron: () => void = () => {};
  onSessions: () => void = () => {};
  onSettings: () => void = () => {};

  /** 菜单展开状态由父组件持有（浮层也在父组件渲染，见文件头注释）*/
  @Link menuOpen: boolean;

  @StorageLink('unreadCount') unreadCount: number = 0;

  build() {
    Stack() {
      // ── ① 标题：全宽 + 居中（放在最底层，不与两侧控件争宽度）──
      Text(this.title)
        .fontSize(FontSize.HEADING)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ left: Size.AVATAR + Space.XL, right: Size.AVATAR + Space.XL })
        .onClick(() => {
          this.onSessions();
        })

      // ── ② 左右控件：浮在标题上层 ──
      Row() {
        // 左上角：圆形「Q」
        Text('Q')
          .fontSize(FontSize.HEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.brand'))
          .textAlign(TextAlign.Center)
          .width(Size.AVATAR)
          .height(Size.AVATAR)
          .padding(0)
          .backgroundColor($r('app.color.brand_soft'))
          .borderRadius(Size.AVATAR / 2)
          .onClick(() => {
            this.menuOpen = true;
          })

        Blank()

        // 右上角：通知（带未读角标）
        Stack({ alignContent: Alignment.TopEnd }) {
          Text('🔔')
            .fontSize(FontSize.BODY)
            .textAlign(TextAlign.Center)
            .width(Size.AVATAR)
            .height(Size.AVATAR)
            .backgroundColor($r('app.color.bg_input'))
            .borderRadius(Size.AVATAR / 2)
            .onClick(() => {
              this.onNotify();
            })

          if (this.unreadCount > 0) {
            Text(badgeText(this.unreadCount))
              .fontSize(FontSize.BADGE)
              .fontColor($r('app.color.text_on_brand'))
              .fontWeight(FontWeight.Medium)
              .backgroundColor($r('app.color.danger'))
              .borderRadius(8)
              .padding({ left: 3, right: 3, top: 0, bottom: 0 })
              .constraintSize({ minWidth: 16 })
              .textAlign(TextAlign.Center)
              .margin({ top: -2, right: -2 })
          }
        }
        .width(Size.AVATAR)
        .height(Size.AVATAR)
      }
      .width('100%')
      .padding({ left: Space.L, right: Space.L })
    }
    .width('100%')
    .height(Size.HEADER_H)
    .backgroundColor($r('app.color.bg_card'))
  }
}
