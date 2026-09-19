/**
 * StreamingBubble —— 流式回复中的气泡（打字机效果）
 *
 * S6 从 ChatPage 的 @Builder 提升为独立 @Component。
 *
 * ⚠️⚠️ 最关键的一条（方案决策 6 / MoA 重点）：
 *   这里**只接 string**，绝不接 ChatMessage 对象！
 *   @Prop 观测不到对象内部字段的变化 —— 如果传对象，流式更新只会渲染出第一个字
 *   然后就永久卡住（这是 ArkUI 状态观测的经典坑）。
 */

@Component
export struct StreamingBubble {
  /**
   * ⚠️ 必须是基础类型，且用 @Link 而非 @Prop。
   *
   * 实测踩坑（S6）：本组件被 ListItem 包裹时，@Prop 的基础类型更新**不会**传导进来
   * —— 流式期间气泡长度纹丝不动（12 秒零更新），直到流结束才一次性出全文。
   * 原因是 ListItem 的复用机制吞掉了 @Prop 的变更通知；@Link 是双向绑定、
   * 直接引用父组件的 @State，不走变更通知这条路，故能正常逐 token 刷新。
   */
  @Link streamContent: string;

  build() {
    Row() {
      Blank()

      Column() {
        Row() {
          Text('🤖')
            .fontSize(16)
            .margin({ right: 6 })
          Text('小Q')
            .fontSize(12)
            .fontColor($r('app.color.brand'))
            .fontWeight(FontWeight.Medium)
        }
        .margin({ bottom: 4 })

        // 流式内容：打字机效果
        Text(this.streamContent)
          .fontSize(15)
          .fontColor($r('app.color.bubble_bot_text'))
          .lineHeight(22)
          .copyOption(CopyOptions.LocalDevice)

        // 还没收到第一个 token 时显示加载动画
        if (this.streamContent.length === 0) {
          Row() {
            LoadingProgress()
              .width(16)
              .height(16)
              .color($r('app.color.brand'))
          }
          .width('100%')
          .margin({ top: 4 })
        }
      }
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor($r('app.color.bubble_bot_bg'))
      .borderRadius(16)
      .shadow({ radius: 4, color: 'rgba(0,0,0,0.06)' })
      .constraintSize({ maxWidth: '80%' })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .margin({ top: 8, bottom: 4 })
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Top)
  }
}
