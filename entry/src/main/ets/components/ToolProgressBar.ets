/**
 * ToolProgressBar —— S45-A 工具执行进度条
 *
 * 解决的问题：Hermes 的 agent 在工具轮期间**不产生文本 token**，
 * 实测一轮 26 次工具调用时首 token 要等 117 秒 —— 这段时间屏幕上
 * 一个字都不动，用户以为卡死。服务端把上游的 hermes.tool.progress
 * 转成 chat_progress 推过来，这里渲染成一块小字列表。
 *
 * S45-A3 行为（用户定）：
 *   · 每个工具带序号 [N]（服务端自增），能看出在推进
 *   · completed 后**不移除**，改成打勾 ✓ 留在原位
 *   · 只有 stream_end 才整块清空
 *
 * ⚠️ ArkTS 注意：@State 对数组**内部元素的修改不敏感**，
 *    所以 ChatPage 每次都是**整体替换数组**来触发刷新。
 */

export class ToolProgressItem {
  /** toolCallId —— 并发场景区分同名工具的多次调用 */
  id: string = '';
  tool: string = '';
  label: string = '';
  emoji: string = '';
  /** 收到该进度的时间（毫秒），用于超时兜底 */
  at: number = 0;
  /** S45-A3: 本轮序号（服务端自增），显示成 [N] */
  index: number = 0;
  /** S45-A3: 是否已执行完成（完成后保留展示，打勾） */
  done: boolean = false;
}

@Component
export struct ToolProgressBar {
  @Prop items: ToolProgressItem[] = [];

  private rowText(it: ToolProgressItem): string {
    const name: string = it.emoji.length > 0 ? (it.emoji + ' ' + it.tool) : it.tool;
    return it.label.length > 0 ? (name + ' · ' + it.label) : name;
  }

  build() {
    if (this.items.length > 0) {
      Column({ space: 2 }) {
        ForEach(this.items, (it: ToolProgressItem) => {
          Row() {
            Text(it.done ? '✓' : '⚙️')
              .fontSize(11)
              .width(18)
            Text(this.rowText(it))
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text('[' + it.index + ']')
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
              .margin({ left: 6 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }, (it: ToolProgressItem) => it.id + '_' + it.done)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.bg_input'))
      .borderRadius(10)
      .margin({ top: 6, bottom: 2 })
      .alignItems(HorizontalAlign.Start)
    }
  }
}
