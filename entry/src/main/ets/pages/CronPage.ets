/**
 * CronPage —— 定时任务面板
 *
 * S10 新增。此前只能 SSH 进去 `hermes cron list` 看任务，APP 里完全没有入口。
 *
 * 交互设计：
 *   - 每个任务一行：名称 + 调度 + 下次执行 + 上次结果 + 开关 + 执行按钮
 *   - 开关 = 启用/暂停（服务端幂等，重复设同值不写盘）
 *   - 暂停中的任务禁用「执行」按钮 —— 服务端对暂停任务会返回 JOB_PAUSED，
 *     与其让用户点了看报错，不如直接置灰
 *   - 全局 busy 标志：连点开关/执行都会被拦掉，避免连发请求产生脏数据
 *   - 错误状态（last_status=error）整行标红并把 last_error 显示出来
 */

import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { cronService, shortDateTime, hasError } from '../services/CronService.ets';
import { CronJob } from '../models/CronModels.ets';
import { rest } from '../core/HermesRest.ets';
import { apiConfig } from '../core/ApiConfig.ets';

@Entry
@Component
struct CronPage {
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State jobs: CronJob[] = [];
  @State busyId: string = '';
  @State enabledCount: number = 0;
  @State errorCount: number = 0;

  @StorageLink('apiKey') apiKey: string = '';

  aboutToAppear(): void {
    this.load();
  }

  onPageShow(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    try {
      await apiConfig.ensureReady(this.apiKey);
      rest.configure(apiConfig.getBaseUrl(), apiConfig.getApiKey());

      const list: CronJob[] = await cronService.fetchJobs();
      this.jobs = list;

      let en: number = 0;
      let er: number = 0;
      for (const j of list) {
        if (j.enabled) {
          en++;
        }
        if (hasError(j)) {
          er++;
        }
      }
      this.enabledCount = en;
      this.errorCount = er;
      this.loading = false;
    } catch (e) {
      this.loading = false;
      this.errorMsg = e instanceof Error ? (e as Error).message : String(e);
      this.showToast('加载失败：' + this.errorMsg);
    }
  }

  /** 启用/暂停。busyId 非空时直接返回，拦掉连点 */
  private async onToggle(j: CronJob, next: boolean): Promise<void> {
    if (this.busyId.length > 0) {
      return;
    }
    this.busyId = j.id;
    try {
      const r = await cronService.toggle(j.id, next);
      this.showToast(r.changed
        ? ((r.enabled ? '已启用：' : '已暂停：') + j.name)
        : '状态未变化');
      await this.load();
    } catch (e) {
      this.showToast('操作失败：' + this.errText(e));
      await this.load();
    } finally {
      this.busyId = '';
    }
  }

  /** 立即执行一次（副作用接口，服务端侧不重试） */
  private async onRun(j: CronJob): Promise<void> {
    if (this.busyId.length > 0) {
      return;
    }
    this.busyId = j.id;
    try {
      await cronService.run(j.id);
      this.showToast('已触发执行：' + j.name);
      // 执行是异步的，稍等再刷新才能看到 last_run_at 变化
      await this.delay(2500);
      await this.load();
    } catch (e) {
      const t: string = this.errText(e);
      if (t.indexOf('JOB_ALREADY_RUNNING') >= 0) {
        this.showToast('该任务正在执行中');
      } else if (t.indexOf('JOB_PAUSED') >= 0) {
        this.showToast('任务已暂停，请先启用');
      } else {
        this.showToast('触发失败：' + t);
      }
    } finally {
      this.busyId = '';
    }
  }

  private errText(e: Object): string {
    return e instanceof Error ? (e as Error).message : String(e);
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  private showToast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 2000 });
    } catch (err) {
      console.error('toast failed');
    }
  }

  @Builder
  OverviewRow(label: string, value: string, color: string) {
    Column() {
      Text(value)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(color)
      Text(label)
        .fontSize(11)
        .fontColor('#999999')
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  JobRow(j: CronJob, idx: number) {
    Column() {
      Row() {
        Column() {
          Text(j.name.length > 0 ? j.name : j.id)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(j.enabled ? '#1A1A2E' : '#999999')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Row() {
            Text(j.schedule)
              .fontSize(11)
              .fontColor('#5B5BD6')
              .backgroundColor('#F0F0FF')
              .borderRadius(6)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            Text('→ ' + shortDateTime(j.nextRunAt))
              .fontSize(11)
              .fontColor('#AAAAAA')
              .margin({ left: 8 })
          }
          .width('100%')
          .margin({ top: 6 })

          Row() {
            Text(j.noAgent ? '脚本' : 'Agent')
              .fontSize(10)
              .fontColor('#888888')
              .backgroundColor('#F0F0F5')
              .borderRadius(4)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            Text('投递 ' + j.deliver)
              .fontSize(10)
              .fontColor('#AAAAAA')
              .margin({ left: 6 })
            Text(j.lastRunAt.length > 0 ? ('上次 ' + shortDateTime(j.lastRunAt)) : '未执行过')
              .fontSize(10)
              .fontColor('#AAAAAA')
              .margin({ left: 6 })
          }
          .width('100%')
          .margin({ top: 5 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 启用开关
        Toggle({ type: ToggleType.Switch, isOn: j.enabled })
          .selectedColor('#5B5BD6')
          .width(44)
          .height(26)
          .enabled(this.busyId.length === 0)
          .onChange((isOn: boolean) => {
            this.onToggle(j, isOn);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 上次失败时把原因显示出来
      if (hasError(j)) {
        Text('⚠️ ' + (j.lastError.length > 0 ? j.lastError : ('上次执行失败（' + j.lastStatus + '）')))
          .fontSize(11)
          .fontColor('#D93025')
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })
      }

      // 操作行
      Row() {
        Text(j.id)
          .fontSize(10)
          .fontColor('#CCCCCC')
          .layoutWeight(1)

        Button() {
          Text(this.busyId === j.id ? '处理中…' : '立即执行')
            .fontSize(12)
            .fontColor(j.enabled && this.busyId.length === 0 ? '#5B5BD6' : '#BBBBBB')
        }
        .height(30)
        .backgroundColor('#F5F5FA')
        .borderRadius(15)
        .padding({ left: 12, right: 12 })
        .enabled(j.enabled && this.busyId.length === 0)
        .onClick(() => {
          this.onRun(j);
        })
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(idx % 2 === 0 ? '#FFFFFF' : '#F7F8FC')
  }

  build() {
    Stack() {
      Column() {
        // 标题栏
        Row() {
          Button() {
            Text('← 返回').fontSize(15).fontColor('#5B5BD6')
          }
          .backgroundColor('transparent')
          .onClick(() => {
            router.back();
          })

          Text('定时任务')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A2E')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)

          Button() {
            Text('刷新').fontSize(15).fontColor('#5B5BD6')
          }
          .backgroundColor('transparent')
          .onClick(() => {
            this.load();
          })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 8, bottom: 8 })
        .backgroundColor('#F8F9FF')

        if (this.loading) {
          Column() {
            LoadingProgress().width(40).height(40).color('#5B5BD6')
            Text('加载中…').fontSize(14).fontColor('#999999').margin({ top: 10 })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.errorMsg.length > 0) {
          Column() {
            Text('⚠️').fontSize(40)
            Text('加载失败').fontSize(16).fontColor('#1A1A2E').margin({ top: 8 })
            Text(this.errorMsg).fontSize(13).fontColor('#999999')
              .margin({ top: 6 }).textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
            Button() {
              Text('重试').fontSize(14).fontColor('#FFFFFF')
            }
            .width(120).height(40).backgroundColor('#5B5BD6').borderRadius(20)
            .margin({ top: 16 })
            .onClick(() => {
              this.load();
            })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          // 概览
          Row() {
            this.OverviewRow('总任务', String(this.jobs.length), '#1A1A2E')
            this.OverviewRow('已启用', String(this.enabledCount), '#2E9E6B')
            this.OverviewRow('暂停', String(this.jobs.length - this.enabledCount), '#C77A20')
            this.OverviewRow('异常', String(this.errorCount), this.errorCount > 0 ? '#D93025' : '#BBBBBB')
          }
          .width('100%')
          .padding({ top: 14, bottom: 14 })
          .backgroundColor('#FFFFFF')

          List() {
            ForEach(this.jobs, (j: CronJob, idx: number) => {
              ListItem() {
                this.JobRow(j, idx)
              }
            }, (j: CronJob) => j.id)
          }
          .width('100%')
          .layoutWeight(1)
          .divider({ strokeWidth: 1, color: '#EEEEF5' })
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)

          Text('共 ' + this.jobs.length + ' 个任务 · 暂停中的任务需先启用才能手动执行')
            .fontSize(11)
            .fontColor('#BBBBBB')
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 8, bottom: 12 })
            .backgroundColor('#F5F5FA')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F5F5FA')
    }
    .width('100%')
    .height('100%')
  }
}
