/**
 * ApproveSheet —— 审批授权卡片（安全扫描确认）
 *
 * S6 从 ChatPage 的 @Builder 提升为独立 @Component。
 *
 * 这是全局审批通道的 UI 层：Gateway 发出审批请求 → WS 转发 → 本卡片弹出
 * → 用户选择 → 回传 choice 给父组件（父组件经 HermesApi.postOnce 提交）。
 *
 * 四个选项的语义（与 Gateway 的 choice 映射对应）：
 *   once    → 同意本次（仅这一次）
 *   session → 本次会话内都同意
 *   always  → 总是同意
 *   deny    → 拒绝
 * ⚠️ 中文文案改动时不要动这 4 个英文值 —— 服务端是按这些字符串解析的。
 */

@Component
export struct ApproveSheet {
  /** 需要执行的命令（可能为空） */
  @Prop command: string = '';
  /** 匹配到的规则标签（可能为空） */
  @Prop patterns: string[] = [];
  /** 提交中（禁用所有按钮，防止重复点击） */
  @Prop inProgress: boolean = false;
  /** 用户选择回调，choice 取值：once / session / always / deny */
  onChoice: (choice: string) => void = () => {};
  /** 点击遮罩关闭 */
  onDismiss: () => void = () => {};

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
        .margin({ bottom: 16 })

        // 命令（代码块风格）
        if (this.command.length > 0) {
          Text('需要执行的命令：')
            .fontSize(13)
            .fontColor('#888888')
            .width('100%')
            .margin({ bottom: 6 })
          Text(this.command)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .fontFamily('Courier')
            .lineHeight(20)
            .width('100%')
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
          .margin({ bottom: 16 })
        }

        // 四个操作按钮
        Column() {
          Row() {
            Button() {
              Row() {
                Text('▶️').fontSize(14)
                Text('仅本次放行').fontSize(13).fontColor('#1A1A2E').margin({ left: 4 })
              }.justifyContent(FlexAlign.Center)
            }
            .layoutWeight(1).height(44).backgroundColor('#F0F5FF').borderRadius(10).margin({ right: 6 })
            .enabled(!this.inProgress)
            .onClick(() => { this.onChoice('once'); })

            Button() {
              Row() {
                Text('🔄').fontSize(14)
                Text('会话放行').fontSize(13).fontColor('#1A1A2E').margin({ left: 4 })
              }.justifyContent(FlexAlign.Center)
            }
            .layoutWeight(1).height(44).backgroundColor('#F0FFF0').borderRadius(10).margin({ left: 6 })
            .enabled(!this.inProgress)
            .onClick(() => { this.onChoice('session'); })
          }
          .width('100%')
          .margin({ bottom: 8 })

          Row() {
            Button() {
              Row() {
                Text('✅').fontSize(14)
                Text('始终允许').fontSize(13).fontColor('#FFFFFF').margin({ left: 4 })
              }.justifyContent(FlexAlign.Center)
            }
            .layoutWeight(1).height(44).backgroundColor('#4CAF50').borderRadius(10).margin({ right: 6 })
            .enabled(!this.inProgress)
            .onClick(() => { this.onChoice('always'); })

            Button() {
              Row() {
                Text('⛔').fontSize(14)
                Text('拒绝').fontSize(13).fontColor('#FFFFFF').margin({ left: 4 })
              }.justifyContent(FlexAlign.Center)
            }
            .layoutWeight(1).height(44).backgroundColor('#FF5252').borderRadius(10).margin({ left: 6 })
            .enabled(!this.inProgress)
            .onClick(() => { this.onChoice('deny'); })
          }
          .width('100%')
        }
        .width('100%')

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
