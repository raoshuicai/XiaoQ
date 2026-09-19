/**
 * AppHeader —— 顶部标题栏
 *
 * S6 从 ChatPage 的 build() 内联布局抽出。S8 加 Token 用量，S9 加通知 + 未读角标。
 * S26 视觉改造：
 *   - 左上角改为**一个圆形「Q」按钮**（浅色底 + 主色字，参考 Kimi 的做法），
 *     原先把 6 个彩色 emoji 平铺在一行 —— 既挤、彩色 emoji 风格也不统一。
 *   - 6 个入口收进「Q」的点击菜单，右侧只保留最高频的 🔔 通知（带未读角标）。
 *   - 颜色全部改走 $r('app.color.xxx')，深浅色自动切换。
 *
 * ⚠️ 菜单用自绘浮层而不是 bindMenu/ActionSheet：那些 API 的对象字面量参数
 *    会被 ArkTS 编译拒绝（之前踩过，一个弹层能凑十几个错），自绘最稳。
 */

import { badgeText } from '../services/NotifyService.ets';
import { FontSize, Radius, Space, Size } from '../core/Theme.ets';

@Component
export struct AppHeader {
  /** 当前会话标题（显示在「Q」右侧）*/
  @Prop title: string = '小Q';
  /** 点击「Q」菜单里的各项 */
  onTokens: () => void = () => {};
  onFiles: () => void = () => {};
  onNotify: () => void = () => {};
  onCron: () => void = () => {};
  onSessions: () => void = () => {};
  onSettings: () => void = () => {};

  /** 未读数：@StorageLink 绑 AppStorage，任何页面写入即自动刷新角标 */
  @StorageLink('unreadCount') unreadCount: number = 0;
  /**
   * 菜单展开状态 —— **由父组件持有**（@Link）。
   * ⚠️ 浮层不能画在本组件里: 本组件根 Stack 的高度是 HEADER_H(52px),
   *    浮层写在里面会被裁剪成 52px 高, 表现为"点了没反应"。
   *    所以这里只负责改状态, 真正渲染菜单的是父组件(ChatPage)的全屏 Stack。
   */
  @Link menuOpen: boolean;

  private openMenu(): void {
    this.menuOpen = true;
  }

  private closeMenu(): void {
    this.menuOpen = false;
  }

  /** 菜单项：点完先关菜单再执行 */
  @Builder
  MenuRow(icon: string, label: string, handler: () => void) {
    Row() {
      Text(icon).fontSize(FontSize.BODY).width(28)
      Text(label)
        .fontSize(FontSize.LABEL)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: Space.M, right: Space.M, top: 13, bottom: 13 })
    .onClick(() => {
      this.closeMenu();
      handler();
    })
  }

  build() {
    // ⚠️ 这里**不要包 Stack**：根容器高度只有 HEADER_H，任何外溢内容都会被裁剪。
    //    菜单浮层由父组件渲染（见 menuOpen 的注释）。
    Row() {
        // 左上角：圆形「Q」
        Text('Q')
          .fontSize(FontSize.HEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.brand'))
          .textAlign(TextAlign.Center)
          .width(Size.AVATAR)
          .height(Size.AVATAR)
          .backgroundColor($r('app.color.brand_soft'))
          .borderRadius(Size.AVATAR / 2)
          .onClick(() => {
            this.openMenu();
          })

        Text(this.title)
          .fontSize(FontSize.HEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .margin({ left: Space.M })
          .onClick(() => {
            this.onSessions();
          })

        // 右侧：只留最高频的通知（带未读角标）
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
      .height(Size.HEADER_H)
      .padding({ left: Space.L, right: Space.L })
      .backgroundColor($r('app.color.bg_card'))

    .width('100%')
    .height(Size.HEADER_H)
  }
}
