/**
 * TokensPage —— Token 用量页
 *
 * S8 新增。这是路线 A 的第一个「纯新增功能」页面：服务端三个接口早就有了，
 * 客户端此前完全没有入口。
 *
 * 布局取舍：
 *   - 顶部三个汇总（今日/本月/累计）用卡片 —— 大数字需要视觉聚焦
 *   - 按模型分布用列表行式 + 交替底色（不用卡片）—— 符合既定的界面偏好
 *   - 近 7 天用等高柱状（不引图表库，避免体积与兼容成本）
 *
 * 数据口径：本月数字应当与 /api/tokens/monthly 里当月那条完全一致（验收要求）。
 */

import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { tokenService, formatTokens, withCommas, shortDate } from '../services/TokenService.ets';
import { rest } from '../core/HermesRest.ets';
import { apiConfig } from '../core/ApiConfig.ets';
import { TokenSummary, DailyPoint, ModelStats, MonthlyPoint } from '../models/ApiModels.ets';

@Entry
@Component
struct TokensPage {
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State summary: TokenSummary = new TokenSummary();
  @State daily: DailyPoint[] = [];
  @State modelRows: ModelStats[] = [];
  @State dailyMax: number = 1;
  @State modelMax: number = 1;

  @StorageLink('apiKey') apiKey: string = '';

  onPageShow(): void {
    // 页面复用时也要刷新（用户可能刚聊完天回来看用量）
    this.loadAll();
  }

  aboutToAppear(): void {
    // ⚠️ 不在这里加载：首次进入时 onPageShow 也会触发，
    //    两处都调会让页面第一件事就发两遍同样的请求。
  }

  private async loadAll(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    try {
      await apiConfig.ensureReady(this.apiKey);
      rest.configure(apiConfig.getBaseUrl(), apiConfig.getApiKey());

      const s: TokenSummary = await tokenService.fetchSummary();
      this.summary = s;

      // 模型行的最大值（用于进度条比例）
      let mm: number = 1;
      for (const m of s.byModel) {
        if (m.totalTokens > mm) {
          mm = m.totalTokens;
        }
      }
      this.modelMax = mm;
      this.modelRows = s.byModel;

      const d = await tokenService.fetchDaily(7);
      // 服务端按日期倒序返回，图表按时间正序更直观
      const asc: DailyPoint[] = [];
      for (let i: number = d.daily.length - 1; i >= 0; i--) {
        asc.push(d.daily[i]);
      }
      let dm: number = 1;
      for (const p of asc) {
        if (p.totalTokens > dm) {
          dm = p.totalTokens;
        }
      }
      this.dailyMax = dm;
      this.daily = asc;

      this.loading = false;
    } catch (e) {
      this.loading = false;
      this.errorMsg = e instanceof Error ? (e as Error).message : String(e);
      this.showToast('加载失败：' + this.errorMsg);
    }
  }

  private showToast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 2000 });
    } catch (err) {
      console.error('toast failed');
    }
  }

  @Builder
  SummaryCard(title: string, mainValue: string, sub1: string, sub2: string, accent: ResourceColor) {
    Column() {
      Text(title)
        .fontSize(13)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
      Text(mainValue)
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor(accent)
        .width('100%')
        .margin({ top: 6 })
      Text(sub1)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ top: 6 })
      Text(sub2)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ top: 2 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 10 })
  }

  build() {
    Stack() {
      Column() {
        // 标题栏
        Row() {
          Button() {
            Text('← 返回')
              .fontSize(15)
              .fontColor($r('app.color.brand'))
          }
          .backgroundColor('transparent')
          .onClick(() => {
            router.back();
          })

          Text('Token 用量')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)

          Button() {
            Text('刷新')
              .fontSize(15)
              .fontColor($r('app.color.brand'))
          }
          .backgroundColor('transparent')
          .onClick(() => {
            this.loadAll();
          })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 8, bottom: 8 })
        .backgroundColor($r('app.color.bg_card'))

        if (this.loading) {
          Column() {
            LoadingProgress().width(40).height(40).color($r('app.color.brand'))
            Text('加载中…').fontSize(14).fontColor($r('app.color.text_tertiary')).margin({ top: 10 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.errorMsg.length > 0) {
          Column() {
            Text('⚠️').fontSize(40)
            Text('加载失败').fontSize(16).fontColor($r('app.color.text_primary')).margin({ top: 8 })
            Text(this.errorMsg).fontSize(13).fontColor($r('app.color.text_tertiary'))
              .margin({ top: 6 })
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
            Button() {
              Text('重试').fontSize(14).fontColor($r('app.color.text_on_brand'))
            }
            .width(120).height(40).backgroundColor($r('app.color.brand')).borderRadius(20)
            .margin({ top: 16 })
            .onClick(() => {
              this.loadAll();
            })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column() {
              // ── 今日 ──
              this.SummaryCard(
                '今日',
                formatTokens(this.summary.today.totalTokens) + ' tokens',
                '输入 ' + formatTokens(this.summary.today.inputTokens)
                + ' · 输出 ' + formatTokens(this.summary.today.outputTokens),
                '',
                $r('app.color.brand')
              )

              // ── 本月 ──
              this.SummaryCard(
                '本月',
                formatTokens(this.summary.thisMonth.totalTokens) + ' tokens',
                this.summary.thisMonth.sessions + ' 个会话 · 活跃 '
                + this.summary.thisMonth.activeDays + ' 天',
                '日均 ' + formatTokens(this.summary.thisMonth.dailyAverage)
                + ' · 按此推算全月约 ' + formatTokens(this.summary.thisMonth.projectedTotal),
                $r('app.color.success')
              )

              // ── 累计 ──
              this.SummaryCard(
                '累计',
                formatTokens(this.summary.allTime.totalTokens) + ' tokens',
                this.summary.allTime.sessions + ' 个会话',
                withCommas(this.summary.allTime.totalTokens) + ' tokens',
                $r('app.color.warning')
              )

              // ── 近 7 天 ──
              Column() {
                Text('近 7 天')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                  .margin({ bottom: 12 })

                Row() {
                  ForEach(this.daily, (p: DailyPoint) => {
                    Column() {
                      // 柱高按当日/最大值比例（最小 4，保证 0 也看得见基线）
                      Column()
                        .width(18)
                        .height(Math.max(4, Math.round(70 * p.totalTokens / this.dailyMax)))
                        .backgroundColor($r('app.color.brand'))
                        .borderRadius(3)
                      Text(shortDate(p.date))
                        .fontSize(10)
                        .fontColor($r('app.color.text_tertiary'))
                        .margin({ top: 6 })
                    }
                    .layoutWeight(1)
                    .justifyContent(FlexAlign.End)
                    .alignItems(HorizontalAlign.Center)
                  })
                }
                .width('100%')
                .height(110)
                .alignItems(VerticalAlign.Bottom)
              }
              .width('100%')
              .padding(16)
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(14)
              .margin({ bottom: 10 })

              // ── 按模型（列表行式 + 交替底色）──
              Column() {
                Text('按模型')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 14, bottom: 10 })

                ForEach(this.modelRows, (m: ModelStats, idx: number) => {
                  Column() {
                    Row() {
                      Text(m.model)
                        .fontSize(14)
                        .fontColor($r('app.color.text_primary'))
                        .layoutWeight(1)
                      Text(formatTokens(m.totalTokens))
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.brand'))
                    }
                    .width('100%')

                    Row() {
                      Text(m.sessions + ' 会话')
                        .fontSize(11)
                        .fontColor($r('app.color.text_tertiary'))
                      Blank()
                      Text('入 ' + formatTokens(m.inputTokens) + ' · 出 ' + formatTokens(m.outputTokens))
                        .fontSize(11)
                        .fontColor($r('app.color.text_tertiary'))
                    }
                    .width('100%')
                    .margin({ top: 4 })

                    // 占比条
                    Row() {
                      Row()
                        .width(Math.max(2, Math.round(100 * m.totalTokens / this.modelMax)) + '%')
                        .height(4)
                        .backgroundColor($r('app.color.brand'))
                        .borderRadius(2)
                    }
                    .width('100%')
                    .height(4)
                    .backgroundColor($r('app.color.divider'))
                    .borderRadius(2)
                    .margin({ top: 6 })
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                  .backgroundColor(idx % 2 === 0 ? $r('app.color.text_on_brand') : $r('app.color.bg_page'))
                })

                Text('数据来源：Hermes state.db（按会话开始时间统计）')
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 12, bottom: 14 })
              }
              .width('100%')
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(14)
              .clip(true)
              .margin({ bottom: 20 })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 12 })
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .width('100%')
    .height('100%')
  }
}
