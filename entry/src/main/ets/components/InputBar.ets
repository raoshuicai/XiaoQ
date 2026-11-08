/**
 * InputBar —— 底部输入区
 *
 * S34 **最终形态** —— 关键洞察：
 *
 * 系统的键盘避让（KeyboardAvoidMode）参照物是**输入框组件本身**（TextArea），
 * 它只保证"输入框可见"，**不会管输入框下面的东西**。
 * 所以如果 ＋/Y/🎤/↑ 排成独立的第二行（在 TextArea 之外），避让后必然是
 * "输入框露出、按钮行被键盘盖住" —— 这就是用户反复反馈的"遮一半"。
 *
 * 正解：把按钮行放进 **TextArea 的范围之内**（用 TextArea 的 padding.bottom
 * 留出按钮高度的空间，按钮用 Stack 浮在那块区域底部）。
 *
 * P1 语音（V3 §3.1 / §3.3）：
 *   - 🎤 在 ↑ 左边；点一下 → 输入区切成「按住 说话」，再点回文本
 *   - ⚠️ TextArea **不能从组件树移除**（它是键盘避让的锚点，移除后切回来会跳高度）。
 *     语音模式只用 visibility(Hidden) 保留布局，再用一个 Row overlay 盖上去。
 *   - 长按录音：Down 150ms 后开始；上滑 >60vp 进取消态（滑回可反悔）；松开发送
 *   - 麦克风权限在**点 🎤 切模式时**申请，不在长按中弹（系统弹窗会派发 TouchType.Cancel，
 *     把刚录的音当取消丢掉）
 */

import { FontSize, Radius, Space, Size } from '../core/Theme.ets';

/** 按钮行高度（px）—— TextArea 的底部 padding 必须 ≥ 它，否则按钮会被文字压住 */
const ACTION_ROW_H: number = 40;
/** 长按进入录音的门槛：按下多久才算长按（防误触） */
const LONG_PRESS_MS: number = 150;
/** 上滑多少 vp 进入取消态（⚠️ 单位是 vp 不是 px，不同 DPI 设备手感才一致） */
const CANCEL_UP_VP: number = 60;
/** 录音上限（与 VoiceRecorder 的 MAX_DURATION_MS 对齐） */
const MAX_REC_SECONDS: number = 60;
/** 危险色（直接写字面量，避免资源缺失导致编译失败） */
const COLOR_DANGER: string = '#DC2626';
const COLOR_TOAST_BG: string = '#99000000';

@Component
export struct InputBar {
  @Link text: string;
  @Prop loading: boolean = false;
  /** S43：YOLO 是否已开启（会话级跳过危险命令审批） */
  @Prop yoloOn: boolean = false;
  /** P1：语音输入模式（文本 ↔ 按住说话） */
  @Link voiceMode: boolean;
  /** P1：是否正在上传+转写（转写中禁止再录） */
  @Prop voiceSending: boolean = false;

  onSend: () => void = () => {};
  /** S43：点击 Y 气泡 —— 切换 YOLO */
  onToggleYolo: () => void = () => {};
  onImage: () => void = () => {};
  onFile: () => void = () => {};
  /** P1 调试入口：从本地选音频文件，走与录音相同的上传/转写链路 */
  onPickAudio: () => void = () => {};
  /** P1：切换语音模式（父组件负责申请麦克风权限） */
  onToggleVoiceMode: () => void = () => {};
  /** P1：开始录音 */
  onRecordStart: () => void = () => {};
  /** P1：结束录音（cancelled=true 表示上滑取消） */
  onRecordEnd: (cancelled: boolean) => void = () => {};

  @State plusOpen: boolean = false;
  /** idle | recording | cancelling */
  @State recState: string = 'idle';
  @State recSeconds: number = 0;

  private downY: number = 0;
  private fingerId: number = -1;
  private pressTimer: number = -1;
  private tickTimer: number = -1;

  aboutToDisappear(): void {
    this.clearTimers();
  }

  @Builder
  PlusItem(icon: string, label: string, handler: () => void) {
    Row() {
      Text(icon).fontSize(18).width(28)
      Text(label)
        .fontSize(FontSize.LABEL)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 14, right: 18, top: 13, bottom: 13 })
    .onClick(() => {
      this.plusOpen = false;
      handler();
    })
  }

  build() {
    Stack() {
      // ─────────── 输入栏本体 ───────────
      Column() {
        // 输入框 + 按钮**同属一个 Stack**：按钮浮在输入框内部底部区域，
        // 这样键盘避让会把它俩当成一个整体。
        Stack({ alignContent: Alignment.Bottom }) {
          TextArea({ placeholder: '给小Q发消息...', text: this.text })
            .width('100%')
            .constraintSize({ minHeight: 24, maxHeight: 300 })
            .backgroundColor($r('app.color.bg_input'))
            .borderRadius(Radius.CARD)
            .fontSize(FontSize.LABEL)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .enabled(!this.loading)
            // ⚠️ P1：语音模式下隐藏但**不移除** —— 它是键盘避让的锚点。
            //    改成 Visibility.None 会从布局里拿掉，切回文本模式时高度会跳。
            .visibility(this.voiceMode ? Visibility.Hidden : Visibility.Visible)
            // ⚠️ 底部 padding 必须 ≥ 按钮行高度：把按钮行的空间"算进"输入框内部，
            //    键盘避让才会连按钮一起保证可见（这是修掉"遮一半"的关键）
            .padding({ left: 14, right: 14, top: 10, bottom: ACTION_ROW_H + 6 })
            .onChange((value: string) => {
              this.text = value;
            })

          // P1：「按住 说话」overlay —— 盖在隐藏的 TextArea 上
          if (this.voiceMode) {
            Row() {
              Text(this.holdLabel())
                .fontSize(FontSize.LABEL)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.recState === 'idle'
                  ? $r('app.color.text_primary') : Color.White)
            }
            .width('100%')
            .height(44)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(this.recState === 'cancelling'
              ? COLOR_DANGER : (this.recState === 'recording'
                ? $r('app.color.brand') : $r('app.color.bg_input')))
            .borderRadius(Radius.CARD)
            .margin({ bottom: ACTION_ROW_H + 6 })
            .onTouch((e: TouchEvent) => {
              this.handleTouch(e);
            })
          }

          // 按钮行：浮在输入框底部（视觉上是"第二行"）
          Row() {
            Text('＋')
              .fontSize(20)
              // 用户要求：默认纯黑字（白底黑字）
              .fontColor($r('app.color.btn_circle_fg'))
              .textAlign(TextAlign.Center)
              .width(32)
              .height(32)
              .backgroundColor($r('app.color.btn_circle_bg'))
              .borderRadius(16)
              .onClick(() => {
                this.plusOpen = !this.plusOpen;
              })

            // ─────── S43：「Y」YOLO 气泡（在 ＋ 右侧）───────
            Text('Y')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.yoloOn ? $r('app.color.text_on_brand') : $r('app.color.btn_circle_fg'))
              .textAlign(TextAlign.Center)
              .width(32)
              .height(32)
              .backgroundColor(this.yoloOn ? $r('app.color.brand') : $r('app.color.btn_circle_bg'))
              .borderRadius(16)
              .margin({ left: 8 })
              .onClick(() => {
                this.onToggleYolo();
              })

            Blank()

            // ─────── P1：「🎤」语音输入（在 ↑ 左侧）───────
            Text('🎤')
              .fontSize(16)
              .textAlign(TextAlign.Center)
              .width(32)
              .height(32)
              .backgroundColor(this.voiceMode ? $r('app.color.brand') : $r('app.color.btn_circle_bg'))
              .borderRadius(16)
              .margin({ right: 8 })
              .onClick(() => {
                if (this.loading || this.voiceSending) {
                  return;
                }
                this.onToggleVoiceMode();
              })

            Text('↑')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.canSend() ? $r('app.color.text_on_brand') : $r('app.color.btn_circle_fg'))
              .textAlign(TextAlign.Center)
              .width(32)
              .height(32)
              .backgroundColor(this.canSend() ? $r('app.color.brand') : $r('app.color.btn_circle_bg'))
              .borderRadius(16)
              .onClick(() => {
                if (this.canSend()) {
                  this.onSend();
                }
              })
          }
          .width('100%')
          .height(ACTION_ROW_H)
          .padding({ left: 10, right: 10 })
        }
        .width('100%')

        // P1：录音状态提示（浮在输入栏下方）
        if (this.recState !== 'idle') {
          Row() {
            Text(this.recState === 'cancelling'
              ? '松开手指，取消发送'
              : ('正在录音 ' + this.recSeconds.toString() + 's  ·  上滑取消'))
              .fontSize(12)
              .fontColor(Color.White)
          }
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .backgroundColor(this.recState === 'cancelling' ? COLOR_DANGER : COLOR_TOAST_BG)
          .borderRadius(12)
          .margin({ top: 6 })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.bg_card'))

      // ─────────── 「＋」菜单 ───────────
      if (this.plusOpen) {
        Column() {
          Blank()

          Column() {
            this.PlusItem('🖼️', '添加图片', (): void => { this.onImage(); })
            this.PlusItem('📎', '添加文件', (): void => { this.onFile(); })
            // P1 调试入口：模拟器录不了音（AVRecorder 在模拟器上录出空文件），
            // 用它把「上传 → 转写 → 发送」整条链跑通，只把录音留给真机。
            this.PlusItem('🎵', '选音频文件', (): void => { this.onPickAudio(); })
          }
          .width('52%')
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Radius.CARD)
          .padding({ top: 6, bottom: 6 })
          .margin({ left: 12, bottom: 110 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.scrim'))
        .onClick(() => {
          this.plusOpen = false;
        })
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.bg_card'))
  }

  private canSend(): boolean {
    return !this.loading && this.text.trim().length > 0;
  }

  private holdLabel(): string {
    if (this.voiceSending) {
      return '识别中…';
    }
    if (this.recState === 'cancelling') {
      return '松开 取消';
    }
    if (this.recState === 'recording') {
      return '松开 发送';
    }
    return '按住 说话';
  }

  /** 长按录音手势：自己算状态（不用 LongPressGesture，它和 Move/Up 在滑动取消场景会打架） */
  private handleTouch(e: TouchEvent): void {
    if (this.voiceSending) {
      return;
    }
    if (e.type === TouchType.Down) {
      this.downY = e.touches.length > 0 ? e.touches[0].y : 0;
      this.fingerId = e.touches.length > 0 ? e.touches[0].id : -1;
      this.pressTimer = setTimeout(() => {
        this.pressTimer = -1;
        this.recState = 'recording';
        this.recSeconds = 0;
        this.startTick();
        this.onRecordStart();
      }, LONG_PRESS_MS);
      return;
    }

    if (e.type === TouchType.Move) {
      if (this.recState === 'idle') {
        return;
      }
      let y: number = this.downY;
      for (let i: number = 0; i < e.touches.length; i++) {
        if (e.touches[i].id === this.fingerId) {
          y = e.touches[i].y;
          break;
        }
      }
      this.recState = (this.downY - y) > CANCEL_UP_VP ? 'cancelling' : 'recording';
      return;
    }

    // Up / Cancel
    if (this.pressTimer >= 0) {
      clearTimeout(this.pressTimer);
      this.pressTimer = -1;
      this.recState = 'idle';
      return;                       // 按下不足 150ms = 误触，不录音
    }
    const cancelled: boolean = this.recState === 'cancelling' || e.type === TouchType.Cancel;
    const wasRecording: boolean = this.recState === 'recording' || this.recState === 'cancelling';
    this.recState = 'idle';
    this.stopTick();
    if (wasRecording) {
      this.onRecordEnd(cancelled);
    }
  }

  private startTick(): void {
    this.stopTick();
    this.tickTimer = setInterval(() => {
      this.recSeconds = this.recSeconds + 1;
      if (this.recSeconds >= MAX_REC_SECONDS) {
        this.stopTick();
        this.recState = 'idle';
        this.onRecordEnd(false);
      }
    }, 1000);
  }

  private stopTick(): void {
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  private clearTimers(): void {
    if (this.pressTimer >= 0) {
      clearTimeout(this.pressTimer);
      this.pressTimer = -1;
    }
    this.stopTick();
  }
}
