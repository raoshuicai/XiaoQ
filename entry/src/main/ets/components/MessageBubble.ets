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
          }
          .margin({ bottom: 4 })
        }

        Text(this.message.content)
          .fontSize(15)
          .fontColor(this.message.role === 'user' ? '#FFFFFF' : '#1A1A2E')
          .lineHeight(22)
          .copyOption(CopyOptions.LocalDevice)
      }
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor(this.message.role === 'user' ? '#5B5BD6' : '#FFFFFF')
      .borderRadius(16)
      .shadow({
        radius: 4,
        color: this.message.role === 'user' ? 'rgba(91,91,214,0.2)' : 'rgba(0,0,0,0.06)'
      })
      .constraintSize({ maxWidth: '80%' })
      .alignItems(HorizontalAlign.Start)

      if (this.message.role === 'assistant') {
        Blank()
      }
    }
    .width('100%')
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
