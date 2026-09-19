/**
 * InputBar —— 底部输入区
 *
 * S6 从 ChatPage 的 build() 内联布局抽出。
 * S21 参考飞书增加下方菜单栏：语音 / 图片 / 文件。
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
  /** S21：菜单栏回调 —— 语音 */
  onVoice: () => void = () => {};
  /** S21：菜单栏回调 —— 图片 */
  onImage: () => void = () => {};
  /** S21：菜单栏回调 —— 文件 */
  onFile: () => void = () => {};

  build() {
    Column() {
      // ── S21：下方菜单栏（参考飞书）──
      // ⚠️ 这里刻意不用 @Builder 封装：@Builder 的形参是**值传递**，
      //    把回调函数当参数传进去后点击可能不触发（实测点了没反应）。
      //    直接内联三个按钮，回调走 this.xxx 最稳。
      Row() {
        Row() {
          Text('🎤').fontSize(15)
          Text('语音').fontSize(13).fontColor('#555566').margin({ left: 4 })
        }
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
        .backgroundColor('#F0F0F5')
        .borderRadius(15)
        .margin({ right: 8 })
        .onClick(() => {
          this.onVoice();
        })

        Row() {
          Text('🖼️').fontSize(15)
          Text('图片').fontSize(13).fontColor('#555566').margin({ left: 4 })
        }
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
        .backgroundColor('#F0F0F5')
        .borderRadius(15)
        .margin({ right: 8 })
        .onClick(() => {
          this.onImage();
        })

        Row() {
          Text('📎').fontSize(15)
          Text('文件').fontSize(13).fontColor('#555566').margin({ left: 4 })
        }
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
        .backgroundColor('#F0F0F5')
        .borderRadius(15)
        .margin({ right: 8 })
        .onClick(() => {
          this.onFile();
        })

        Blank()
      }
      .width('100%')
      .padding({ bottom: 8 })

      // ── 输入行 ──
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
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 12, top: 8 })
    .backgroundColor('#FFFFFF')
  }
}
