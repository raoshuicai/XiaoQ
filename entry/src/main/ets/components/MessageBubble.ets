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
        }

        // ⚠️ 这里**不要**写 .width('100%')：
        //    外层 Column 用的是 maxWidth 约束，Text 再声明 100% 会形成
        //    "Column 宽度取决于 Text、Text 宽度又取决于 Column" 的循环依赖，
        //    ArkUI 算错后文字会溢出气泡右边界 —— 用户看到的就是"最右边一列字被挡"。
        //    去掉后由 Column 按内容自适应，配合 maxWidth 限制上限即可。
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
      // S21：小Q 的答复占满整行宽度（用户反馈原来 80% 太窄、正文被挤）；
      //     用户自己的消息保持 80%（气泡短、右对齐，与飞书一致）
      .constraintSize({ maxWidth: this.message.role === 'assistant' ? '100%' : '80%' })
      .alignItems(HorizontalAlign.Start)

      if (this.message.role === 'assistant') {
        Blank()
      }
    }
    .width('100%')
    // S24 修：两侧留白写反了 —— 用户消息右对齐，**右侧**必须有留白，否则最右一列字被屏幕边缘挡掉；
    //        小Q 消息左对齐，**左侧**要有留白。空白侧（用户左侧 / 小Q 右侧）留小一点即可。
    .padding({ left: this.message.role === 'user' ? 6 : 14,
               right: this.message.role === 'user' ? 14 : 6 })
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
