/**
 * ApproveSheet —— 审批授权卡片（安全扫描确认）
 *
 * S6 从 ChatPage 的 @Builder 提升为独立 @Component。
 * S11 增强四项：
 *   ① 长命令可滚动（Scroll + 最大高度 240vp，原先超长命令会把卡片撑破）
 *   ② 显示触发上下文（description / 哪个会话 / 收到时间）
 *   ③ 「始终允许」需二次确认（这是权限最高的一档，误点代价大）
 *   ④ 审批历史（不放这里，见 ApproveHistoryPage —— 入口在设置面板）
 *
 * 四个选项的语义（与 Gateway 的 choice 映射对应）：
 *   once    → 同意本次（仅这一次）
 *   session → 本次会话内都同意
 *   always  → 总是同意
 *   deny    → 拒绝
 * ⚠️ 中文文案改动时不要动这 4 个英文值 —— 服务端是按这些字符串解析的。
 */

import { clockText } from '../services/ApproveService.ets';

@Component
export struct ApproveSheet {
  /** 需要执行的命令（可能为空） */
  @Prop command: string = '';
  /** 匹配到的规则标签（可能为空） */
  @Prop patterns: string[] = [];
  /** S11：Gateway 给的触发说明 */
  @Prop description: string = '';
  /** S11：哪个会话触发的 */
  @Prop sessionId: string = '';
  /** S11：收到时间（毫秒） */
  @Prop receivedAt: number = 0;
  /** 提交中（禁用所有按钮，防止重复点击） */
  @Prop inProgress: boolean = false;
  /** 用户选择回调，choice 取值：once / session / always / deny */
  onChoice: (choice: string) => void = () => {};
  /** 点击遮罩关闭 */
  onDismiss: () => void = () => {};

  /** S11：是否处于「始终允许」的二次确认态 */
  @State confirmingAlways: boolean = false;

  @Builder
  ChoiceButton(icon: string, label: string, bg: string, fg: string,
               choice: string, topMargin: number, bottomMargin: number) {
    Button() {
      Row() {
        Text(icon).fontSize(14)
        Text(label).fontSize(13).fontColor(fg).margin({ left: 4 })
      }.justifyContent(FlexAlign.Center)
    }
    .layoutWeight(1)
    .height(44)
    .backgroundColor(bg)
    .borderRadius(10)
    .margin({ left: topMargin, right: bottomMargin })
    .enabled(!this.inProgress)
    .onClick(() => {
      // S11：始终允许需要二次确认
      if (choice === 'always') {
        this.confirmingAlways = true;
      } else {
        this.onChoice(choice);
      }
    })
  }

  build() {
    Column() {
      Column() {
        // 头部
        Row() {
          Text('🔐')
            .fontSize(28)
            .margin({ right: 10 })
          Column() {
            Text('授权请求')
              .fontSize(12)
              .fontColor('#888888')
            Text('安全扫描')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1A1A2E')
              .lineHeight(24)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .margin({ bottom: 12 })

        // ── S11 ②：触发上下文 ──
        if (this.description.length > 0
          || this.sessionId.length > 0 || this.receivedAt > 0) {
          Column() {
            if (this.description.length > 0) {
              Row() {
                Text('触发原因')
                  .fontSize(11).fontColor('#999999').width(58)
                Text(this.description)
                  .fontSize(11).fontColor('#555555').layoutWeight(1)
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }
            if (this.sessionId.length > 0) {
              Row() {
                Text('会话')
                  .fontSize(11).fontColor('#999999').width(58)
                Text(this.sessionId)
                  .fontSize(11).fontColor('#555555').layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .margin({ top: 4 })
            }
            Row() {
              Text('收到时间')
                .fontSize(11).fontColor('#999999').width(58)
              Text(clockText(this.receivedAt))
                .fontSize(11).fontColor('#555555').layoutWeight(1)
            }
            .width('100%')
            .margin({ top: 4 })
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .backgroundColor('#F8F8FC')
          .borderRadius(8)
          .margin({ bottom: 12 })
        }

        // ── 命令（代码块风格，S11 ① 长命令可滚动）──
        if (this.command.length > 0) {
          Text('需要执行的命令：')
            .fontSize(13)
            .fontColor('#888888')
            .width('100%')
            .margin({ bottom: 6 })

          Scroll() {
            Text(this.command)
              .fontSize(13)
              .fontColor('#FFFFFF')
              .fontFamily('Courier')
              .lineHeight(20)
              .width('100%')
          }
          .width('100%')
          // S11 ①：给命令区一个高度上限，超长命令在卡片内滚动而不是撑破卡片
          .constraintSize({ maxHeight: 240 })
          .scrollBar(BarState.Auto)
          .align(Alignment.TopStart)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor('#1A1A2E')
          .borderRadius(8)
          .margin({ bottom: 12 })
        }

        // 匹配模式标签
        if (this.patterns.length > 0) {
          Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
            ForEach(this.patterns, (pattern: string) => {
              Text(pattern)
                .fontSize(11)
                .fontColor('#5B5BD6')
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .backgroundColor('#F0F0FF')
                .borderRadius(10)
                .margin({ right: 4, bottom: 4 })
            })
          }
          .width('100%')
          .margin({ bottom: 12 })
        }

        // ── S11 ③：「始终允许」的二次确认 ──
        if (this.confirmingAlways) {
          Column() {
            Text('⚠️ 确认「始终允许」？')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor('#C77A20')
              .width('100%')
            Text('此后同类操作将不再询问，直接执行。这是权限最高的一档，请确认你了解影响。')
              .fontSize(11)
              .fontColor('#888888')
              .lineHeight(17)
              .width('100%')
              .margin({ top: 6 })

            Row() {
              Button() {
                Text('取消').fontSize(13).fontColor('#666666')
              }
              .layoutWeight(1).height(40)
              .backgroundColor('#F0F0F5').borderRadius(10)
              .margin({ right: 6 })
              .onClick(() => {
                this.confirmingAlways = false;
              })

              Button() {
                Text('确认始终允许').fontSize(13).fontColor('#FFFFFF')
              }
              .layoutWeight(1).height(40)
              .backgroundColor('#C77A20').borderRadius(10)
              .margin({ left: 6 })
              .enabled(!this.inProgress)
              .onClick(() => {
                this.confirmingAlways = false;
                this.onChoice('always');
              })
            }
            .width('100%')
            .margin({ top: 12 })
          }
          .width('100%')
          .padding(12)
          .backgroundColor('#FFF8ED')
          .borderRadius(10)
          .margin({ bottom: 4 })
        } else {
          // ── 四个操作按钮 ──
          Column() {
            Row() {
              this.ChoiceButton('▶️', '仅本次放行', '#F0F5FF', '#1A1A2E', 'once', 0, 6)
              this.ChoiceButton('🔄', '会话放行', '#F0FFF0', '#1A1A2E', 'session', 6, 0)
            }
            .width('100%')
            .margin({ bottom: 8 })

            Row() {
              this.ChoiceButton('✅', '始终允许', '#4CAF50', '#FFFFFF', 'always', 0, 6)
              this.ChoiceButton('⛔', '拒绝', '#FF5252', '#FFFFFF', 'deny', 6, 0)
            }
            .width('100%')
          }
          .width('100%')
        }

        // 处理中
        if (this.inProgress) {
          Row() {
            LoadingProgress().width(16).height(16).color('#5B5BD6')
            Text('处理中...').fontSize(13).fontColor('#999999').margin({ left: 8 })
          }.width('100%').justifyContent(FlexAlign.Center).margin({ top: 12 })
        }
      }
      .width('100%')
      .padding(24)
      .backgroundColor('#FFFFFF')
      .borderRadius({ topLeft: 20, topRight: 20 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
    .justifyContent(FlexAlign.End)
    .onClick(() => {
      this.onDismiss();
    })
  }
}
