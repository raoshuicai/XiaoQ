/**
 * MessageBubble —— 单条消息气泡
 *
 * S6 从 ChatPage 的 @Builder 提升为独立 @Component。
 *
 * ⚠️ 传参要点（方案决策 6）：
 *   message 是不可变对象（每次追加新消息都是新实例），所以用 @Prop 深拷贝是安全的。
 *   千万不要在这里做「就地修改 message.content」—— @Prop 观测不到深层变更。
 */

import { ChatMessage, MsgMetrics } from '../models/ChatModels.ets';

/**
 * 消息时间格式化（S21）。
 * 规则（用户指定）：当天 → `HH:mm`；非当天 → `MM-DD HH:mm`（都是 24 小时制）。
 */
/**
 * S45-B2：用户角色的显示名。
 * 需求原文：「后面把我的角色定义为阿水，把时间显示在阿水右边」。
 */
const USER_NAME: string = '阿水';

function fmtMsgTime(ms: number | undefined, todayKey: string): string {
  // V4-A7：跨天判断不再用 new Date()（时间流逝不触发重绘，#IKJRZG 根因），
  //   改比对 todayKey（AppStorage 驱动，跨天时 @StorageProp 自动刷新本组件）。
  if (ms === undefined || ms <= 0) {
    return '';
  }
  const d: Date = new Date(ms);
  const pad = (n: number): string => (n < 10 ? '0' + n : String(n));
  const hhmm: string = pad(d.getHours()) + ':' + pad(d.getMinutes());
  const dKey: string = d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
  if (dKey === todayKey) {
    return hhmm;                                    // 当天：HH:MM
  }
  // S45-B3：非当天要带日期。跨年时再补上年份，避免 '09-22 06:57' 有歧义。
  const md: string = pad(d.getMonth() + 1) + '-' + pad(d.getDate());
  if (String(d.getFullYear()) !== todayKey.substring(0, 4)) {
    return d.getFullYear().toString() + '-' + md + ' ' + hhmm;   // YYYY-MM-DD HH:MM
  }
  return md + ' ' + hhmm;                           // MM-DD HH:MM
}

/**
 * S41：把本轮性能指标渲染成一行小字。
 * 格式与 Desktop 的 perf-metrics footer 保持一致：⚡ TTFT 1.59s · TPS 108 tok/s · KV 命中 99.7% · 7 次调用
 * 任何一项缺失就跳过它；全缺则返回空串（调用方据此不渲染）。
 */
function fmtMetrics(m: MsgMetrics | undefined): string {
  if (m === undefined) {
    return '';
  }
  const parts: string[] = [];
  if (m.ttft_ms !== undefined && m.ttft_ms > 0) {
    parts.push('TTFT ' + (m.ttft_ms / 1000).toFixed(2) + 's');
  }
  if (m.tps !== undefined && m.tps > 0) {
    parts.push('TPS ' + m.tps.toFixed(0) + ' tok/s');
  }
  if (m.kv_hit !== undefined && m.kv_hit > 0) {
    parts.push('KV 命中 ' + (m.kv_hit * 100).toFixed(1) + '%');
  }
  if (m.calls !== undefined && m.calls > 0) {
    parts.push(m.calls.toString() + ' 次调用');
  }
  if (parts.length === 0) {
    return '';
  }
  return '⚡ ' + parts.join(' · ');
}

@Component
export struct MessageBubble {
  // V4-A7：跨天键（AppStorage 驱动重绘，绕开 ForEach 复用不刷新问题）
  @StorageProp('xiaoq_chat_today_key') todayKey: string = '';
  @Prop message: ChatMessage;
  index: number = 0;
  /** 长按删除回调（父组件负责弹确认框） */
  onDelete: (index: number) => void = () => {};

  build() {
    // S45-B2：最外层 Column —— 承载「名称/时间行」+「气泡行」两部分。
    // 为什么必须这样分层：
    //   ⚠️ 时间行若写在气泡 Column **内部**，气泡 Column 的宽度由内容决定，
    //      而时间行再声明 width('100%') 会形成「列宽取决于行宽、行宽取决于列宽」
    //      的循环依赖 —— 实测被算成 5px 宽，时间戳几乎不可见（用户反馈"看不到"）。
    //   放到外层后，width('100%') 相对整行宽度，安全。
    Column() {
      // ── ① 名称 + 时间行（在气泡上方）──
      if (this.message.role === 'assistant') {
        // 小Q：左对齐，头像 + 名称 + 时间
        Row() {
          Image($r('app.media.bot_avatar'))
            .width(20)
            .height(20)
            .borderRadius(10)
            .margin({ right: 6 })
          Text('小Q')
            .fontSize(12)
            .fontColor($r('app.color.brand'))
            .fontWeight(FontWeight.Medium)
          // S21：时间信息（当天=时:分 / 非当天=月-日 时:分）
          if (fmtMsgTime(this.message.createdAt, this.todayKey).length > 0) {
            Text(fmtMsgTime(this.message.createdAt, this.todayKey))
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ left: 8 })
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        .margin({ bottom: 4 })
      } else if (fmtMsgTime(this.message.createdAt, this.todayKey).length > 0
                 || USER_NAME.length > 0) {
        // S45-B2：用户自己发的消息 —— 右对齐显示「阿水 + 时间」。
        // 需求原文："把时间显示在阿水右边"，与左侧「小Q + 时间」左右对称。
        Row() {
          Text(USER_NAME)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .fontWeight(FontWeight.Medium)
          if (fmtMsgTime(this.message.createdAt, this.todayKey).length > 0) {
            Text(fmtMsgTime(this.message.createdAt, this.todayKey))
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ left: 8 })
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ bottom: 4 })
      }

      // ── ② 气泡行 ──
      Row() {
        if (this.message.role === 'user') {
          Blank()
        }

        Column() {

        // ⚠️ 这里**不要**写 .width('100%')：
        //    外层 Column 用的是 maxWidth 约束，Text 再声明 100% 会形成
        //    "Column 宽度取决于 Text、Text 宽度又取决于 Column" 的循环依赖，
        //    ArkUI 算错后文字会溢出气泡右边界 —— 用户看到的就是"最右边一列字被挡"。
        //    去掉后由 Column 按内容自适应，配合 maxWidth 限制上限即可。
        // S41：指标行（TTFT / TPS / KV 命中）—— 只在 assistant 且拿到 metrics 时显示
        if (this.message.role === 'assistant' && this.message.metrics !== undefined
            && fmtMetrics(this.message.metrics).length > 0) {
          Text(fmtMetrics(this.message.metrics))
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ top: 8 })
            .copyOption(CopyOptions.LocalDevice)
        }

        Text(this.message.content)
          .fontSize(15)
          .fontColor(this.message.role === 'user' ? $r('app.color.bubble_user_text') : $r('app.color.bubble_bot_text'))
          .lineHeight(22)
          .copyOption(CopyOptions.LocalDevice)
      }
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor(this.message.role === 'user' ? $r('app.color.bubble_user_bg') : $r('app.color.bubble_bot_bg'))
      .borderRadius(16)
      // S26：去掉阴影 —— 在浅灰底上阴影显脏；小Q 气泡改用极细描边区分
      .border(this.message.role === 'assistant'
        ? { width: 1, color: $r('app.color.border_subtle') }
        : { width: 0 })
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
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .margin({ top: 8, bottom: 4 })
    .gesture(
      LongPressGesture({ repeat: false, duration: 500 })
        .onAction(() => {
          this.onDelete(this.index);
        })
    )
  }
}
