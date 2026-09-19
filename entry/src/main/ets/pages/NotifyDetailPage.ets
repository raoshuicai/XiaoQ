/**
 * NotifyDetailPage —— 通知详情页（S16）
 *
 * 为什么单独做一个页面：通知列表里每条只显示 4 行摘要（`maxLines(4)` + Ellipsis），
 * 而推送内容经常是整篇日报 —— 用户点进去只能看到一个预览，看不到完整内容。
 * 列表页的 onClick 原先只做「标记已读」，没有任何打开动作。
 *
 * ⚠️ 参数传递用 AppStorage 而不是 router.pushUrl({ params })}：
 *    ArkTS 对路由参数有序列化限制，传对象要走显式类型；而消息体本身就是个现成对象，
 *    放进 AppStorage 读一次即可，少一层转换也少一个出错点。
 */

import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { PushMessage } from '../models/NotifyModels.ets';

/** AppStorage key：待展示的通知 */
export const NOTIFY_DETAIL_KEY: string = 'notifyDetail';

@Entry
@Component
struct NotifyDetailPage {
  @StorageLink(NOTIFY_DETAIL_KEY) detail: PushMessage | null = null;

  private copyAll(): void {
    const m: PushMessage | null = this.detail;
    if (m === null) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,
        m.title + '\n\n' + m.body);
      pasteboard.getSystemPasteboard().setDataSync(data);
      promptAction.showToast({ message: '已复制全文' });
    } catch (e) {
      promptAction.showToast({ message: '复制失败' });
    }
  }

  @Builder
  metaRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(12).fontColor($r('app.color.text_tertiary')).width(64)
      Text(value).fontSize(12).fontColor($r('app.color.text_secondary')).layoutWeight(1)
    }
    .width('100%')
    .margin({ top: 6 })
    .alignItems(VerticalAlign.Top)
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Button() {
          Text('← 返回').fontSize(15).fontColor($r('app.color.brand'))
        }
        .backgroundColor('transparent')
        .onClick(() => { router.back(); })
        .padding(0)

        Text('通知详情')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)

        Button() {
          Text('复制').fontSize(15).fontColor($r('app.color.brand'))
        }
        .backgroundColor('transparent')
        .onClick(() => { this.copyAll(); })
        .padding(0)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 12 })
      .backgroundColor($r('app.color.bg_card'))

      if (this.detail === null) {
        Column() {
          Text('没有可显示的通知').fontSize(14).fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            Text(this.detail!.title.length > 0 ? this.detail!.title : '(无标题)')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .margin({ bottom: 10 })

            this.metaRow('时间', this.detail!.createdAt)
            this.metaRow('来源', this.detail!.source.length > 0 ? this.detail!.source : '-')
            this.metaRow('状态', this.detail!.readAt.length > 0 ? '已读' : '未读')

            Divider()
              .color($r('app.color.divider'))
              .margin({ top: 14, bottom: 14 })

            // 完整内容：不限行数、可滚动
            // ⚠️ API 24 的 textSelectable 已从 boolean 改为 TextSelectableMode
            Text(this.detail!.body)
              .fontSize(15)
              .fontColor($r('app.color.text_secondary'))
              .lineHeight(24)
              .width('100%')
              .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
          }
          .width('100%')
          .padding(18)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
          .margin({ top: 12, left: 12, right: 12 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        .backgroundColor($r('app.color.bg_page'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
