/**
 * ApproveHistoryPage —— 审批历史
 *
 * S11 新增。审批卡片是临时浮层，答完就没了；事后想回顾「我什么时候批准过什么」
 * 完全没有痕迹。本页补上：本地保存最近 20 条（含未处理就关掉的）。
 *
 * 入口在「设置」面板 —— 审批是低频但需要留痕的操作，不占顶部按钮位。
 *
 * 数据来源：ApproveService.history（Preferences 持久化，跨重启保留）。
 */

import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { approveService, choiceLabel, clockText, ApproveRequest } from '../services/ApproveService.ets';

@Entry
@Component
struct ApproveHistoryPage {
  @State items: ApproveRequest[] = [];
  @State filterChoice: string = 'all';

  aboutToAppear(): void {
    // ⚠️ 不在这里 refresh：首次进入时 onPageShow 也会触发（本地数据，无需重复拉）
  }

  onPageShow(): void {
    this.refresh();
  }

  private refresh(): void {
    const all: ApproveRequest[] = approveService.getHistory();
    if (this.filterChoice === 'all') {
      this.items = all;
      return;
    }
    const out: ApproveRequest[] = [];
    for (const it of all) {
      if (it.choice === this.filterChoice) {
        out.push(it);
      }
    }
    this.items = out;
  }

  private setFilter(k: string): void {
    this.filterChoice = k;
    this.refresh();
  }

  private doClear(): void {
    promptAction.showDialog({
      title: '清空审批历史',
      message: '将删除本地保存的 ' + approveService.getHistory().length + ' 条记录，无法恢复。',
      buttons: [
        { text: '取消', color: $r('app.color.text_secondary') },
        { text: '清空', color: $r('app.color.danger') }
      ]
    }).then((r) => {
      if (r.index === 1) {
        approveService.clearHistory().then(() => {
          this.refresh();
          this.showToast('已清空');
        });
      }
    });
  }

  private showToast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 2000 });
    } catch (err) {
      console.error('toast failed');
    }
  }

  /** choice 对应的配色 */
  private choiceColor(c: string): ResourceColor {
    if (c === 'deny') {
      return $r('app.color.danger');
    }
    if (c === 'always') {
      return $r('app.color.warning');
    }
    if (c === 'dismissed') {
      return $r('app.color.text_tertiary');
    }
    return $r('app.color.brand');
  }

  @Builder
  FilterChip(key: string, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.filterChoice === key ? $r('app.color.text_on_brand') : $r('app.color.text_secondary'))
      .backgroundColor(this.filterChoice === key ? $r('app.color.brand') : $r('app.color.bg_input'))
      .borderRadius(14)
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .margin({ right: 8 })
      .onClick(() => {
        this.setFilter(key);
      })
  }

  build() {
    Stack() {
      Column() {
        // 标题栏
        Row() {
          Button() {
            Text('← 返回').fontSize(15).fontColor($r('app.color.brand'))
          }
          .backgroundColor('transparent')
          .onClick(() => {
            router.back();
          })

          Text('审批历史')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)

          Button() {
            Text('清空').fontSize(15).fontColor($r('app.color.danger'))
          }
          .backgroundColor('transparent')
          .enabled(approveService.getHistory().length > 0)
          .onClick(() => {
            this.doClear();
          })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 8, bottom: 8 })
        .backgroundColor($r('app.color.bg_card'))

        // 筛选
        Row() {
          this.FilterChip('all', '全部')
          this.FilterChip('once', '仅本次')
          this.FilterChip('session', '会话')
          this.FilterChip('always', '始终允许')
          this.FilterChip('deny', '拒绝')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .backgroundColor($r('app.color.bg_card'))

        if (this.items.length === 0) {
          Column() {
            Text('🗂').fontSize(44)
            Text(approveService.getHistory().length === 0
              ? '还没有审批记录'
              : '没有该类型的记录')
              .fontSize(14).fontColor($r('app.color.text_tertiary')).margin({ top: 10 })
            Text('审批卡片处理后会在这里留下记录，最多保留最近 20 条')
              .fontSize(11).fontColor($r('app.color.text_tertiary'))
              .margin({ top: 8 })
              .textAlign(TextAlign.Center)
              .padding({ left: 40, right: 40 })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          List() {
            ForEach(this.items, (it: ApproveRequest, idx: number) => {
              ListItem() {
                Column() {
                  Row() {
                    Text(choiceLabel(it.choice))
                      .fontSize(12)
                      .fontColor($r('app.color.text_on_brand'))
                      .backgroundColor(this.choiceColor(it.choice))
                      .borderRadius(8)
                      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    Blank()
                    Text(clockText(it.handledAt))
                      .fontSize(11)
                      .fontColor($r('app.color.text_tertiary'))
                  }
                  .width('100%')

                  if (it.description.length > 0) {
                    Text(it.description)
                      .fontSize(12)
                      .fontColor($r('app.color.text_secondary'))
                      .lineHeight(18)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                      .margin({ top: 8 })
                  }

                  if (it.command.length > 0) {
                    Text(it.command)
                      .fontSize(11)
                      .fontColor($r('app.color.text_secondary'))
                      .fontFamily('Courier')
                      .lineHeight(17)
                      .maxLines(3)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                      .padding(8)
                      .backgroundColor($r('app.color.bg_page'))
                      .borderRadius(6)
                      .margin({ top: 8 })
                  }

                  if (it.sessionId.length > 0) {
                    Text('会话 ' + it.sessionId)
                      .fontSize(10)
                      .fontColor($r('app.color.text_tertiary'))
                      .width('100%')
                      .margin({ top: 6 })
                  }
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .backgroundColor(idx % 2 === 0 ? $r('app.color.text_on_brand') : $r('app.color.bg_page'))
                .alignItems(HorizontalAlign.Start)
              }
            }, (it: ApproveRequest) => it.runId + '_' + it.handledAt)
          }
          .width('100%')
          .layoutWeight(1)
          .divider({ strokeWidth: 1, color: $r('app.color.divider') })
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
        }

        Text('共 ' + this.items.length + ' 条 · 本地保存最近 20 条')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 8, bottom: 12 })
          .backgroundColor($r('app.color.bg_page'))
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .width('100%')
    .height('100%')
  }
}
