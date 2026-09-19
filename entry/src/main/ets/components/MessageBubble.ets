/**
 * MessageBubble —— 单条消息气泡
 *
 * S6 从 ChatPage 的 @Builder 提升为独立 @Component。
 *
 * ⚠️ 传参要点（方案决策 6）：
 *   message 是不可变对象（每次追加新消息都是新实例），所以用 @Prop 深拷贝是安全的。
 *   千万不要在这里做「就地修改 message.content」—— @Prop 观测不到深层变更。
 */

import { ChatMessage } from '../models/ChatModels.ets';

/**
 * 消息时间格式化（S21）。
 * 规则（用户指定）：当天 → `HH:mm`；非当天 → `MM-DD HH:mm`（都是 24 小时制）。
 */
function fmtMsgTime(ms: number | undefined): string {
  if (ms === undefined || ms <= 0) {
    return '';
  }
  const d: Date = new Date(ms);
  const now: Date = new Date();
  const pad = (n: number): string => (n < 10 ? '0' + n : String(n));
  const hhmm: string = pad(d.getHours()) + ':' + pad(d.getMinutes());
  const sameDay: boolean = d.getFullYear() === now.getFullYear()
    && d.getMonth() === now.getMonth()
    && d.getDate() === now.getDate();
  if (sameDay) {
    return hhmm;
  }
  return pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + hhmm;
}

@Component
export struct MessageBubble {
  @Prop message: ChatMessage;
  index: number = 0;
  /** 长按删除回调（父组件负责弹确认框） */
  onDelete: (index: number) => void = () => {};

  build() {
    Row() {
      if (this.message.role === 'user') {
        Blank()
      }

      Column() {
        if (this.message.role === 'assistant') {
          Row() {
            Image($r('app.media.bot_avatar'))
              .width(20)
              .height(20)
              .borderRadius(10)
              .margin({ right: 6 })
            Text('小Q')
              .fontSize(12)
              .fontColor('#5B5BD6')
              .fontWeight(FontWeight.Medium)
            // S21：时间信息（当天=时:分 / 非当天=月-日 时:分）
            if (fmtMsgTime(this.message.createdAt).length > 0) {
              Text(fmtMsgTime(this.message.createdAt))
                .fontSize(11)
                .fontColor('#AAAAAA')
                .margin({ left: 8 })
            }
          }
          .margin({ bottom: 4 })
          .width('100%')
        }

        Text(this.message.content)
          .fontSize(15)
          .fontColor(this.message.role === 'user' ? '#FFFFFF' : '#1A1A2E')
          .lineHeight(22)
          .copyOption(CopyOptions.LocalDevice)
          .width('100%')
      }
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor(this.message.role === 'user' ? '#5B5BD6' : '#FFFFFF')
      .borderRadius(16)
      .shadow({
        radius: 4,
        color: this.message.role === 'user' ? 'rgba(91,91,214,0.2)' : 'rgba(0,0,0,0.06)'
      })
      // S21：小Q 的答复占满整行宽度（用户反馈原来 80% 太窄、正文被挤）；
      //     用户自己的消息保持 80%（气泡短、右对齐，与飞书一致）
      .constraintSize({ maxWidth: this.message.role === 'assistant' ? '100%' : '80%' })
      .alignItems(HorizontalAlign.Start)

      if (this.message.role === 'assistant') {
        Blank()
      }
    }
    .width('100%')
    // S21：两边只留一点空白（原来靠气泡 maxWidth 留白，现在由外层 padding 控制）
    .padding({ left: this.message.role === 'user' ? 12 : 6,
               right: this.message.role === 'user' ? 6 : 12 })
    .margin({ top: 8, bottom: 4 })
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Top)
    .gesture(
      LongPressGesture({ repeat: false, duration: 500 })
        .onAction(() => {
          this.onDelete(this.index);
        })
    )
  }
}
