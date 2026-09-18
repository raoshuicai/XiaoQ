/**
 * InputBar —— 底部输入区
 *
 * S6 从 ChatPage 的 build() 内联布局抽出。
 *
 * 输入框用 @Link 与父组件双向绑定（而不是内部 @State + 回传），
 * 因为父组件在发送成功后需要主动清空输入框 —— 单向数据流做不到这一点。
 */

@Component
export struct InputBar {
  /** 与父组件的 inputText 双向绑定 */
  @Link text: string;
  /** 请求中：输入框禁用、按钮变 loading */
  @Prop loading: boolean = false;
  /** 发送回调（父组件负责校验与清空） */
  onSend: () => void = () => {};

  build() {
    Row() {
      TextInput({ placeholder: '给小Q发消息...', text: this.text })
        .layoutWeight(1)
        .height(44)
        .backgroundColor('#F0F0F5')
        .borderRadius(22)
        .padding({ left: 16, right: 16 })
        .onChange((value: string) => {
          this.text = value;
        })
        .onSubmit(() => {
          this.onSend();
        })
        .enabled(!this.loading)

      Button() {
        if (this.loading) {
          LoadingProgress().width(20).height(20).color('#FFFFFF')
        } else {
          Text('发送').fontSize(14).fontColor('#FFFFFF')
        }
      }
      .width(60).height(40)
      .backgroundColor(this.loading ? '#9999CC' : '#5B5BD6')
      .borderRadius(20).margin({ left: 8 })
      .enabled(!this.loading && this.text.trim().length > 0)
      .onClick(() => {
        this.onSend();
      })
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 12, top: 8 })
    .backgroundColor('#FFFFFF')
  }
}
