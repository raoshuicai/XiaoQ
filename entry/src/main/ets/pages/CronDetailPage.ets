/**
 * CronDetailPage —— 定时任务详情 / 编辑 / 运行历史
 *
 * S10 追加。此前列表只能看个大概，点不进去；本页补齐「查看具体内容 + 编辑」。
 *
 * 三块内容：
 *   1. 基本信息 + 调度 + 执行情况（含完整 last_error）
 *   2. 任务内容：Agent 类型显示 prompt 全文；脚本类型显示脚本名
 *   3. 运行历史：读 output/<job_id>/ 下的历史输出，点开就地展开
 *
 * 编辑范围（跟随服务端白名单）：
 *   ✅ name、schedule（表达式）—— schedule 变更由服务端自动重算 next_run_at
 *   ❌ prompt / script / no_agent —— 改动面大，继续在 Hermes 侧用 CLI 改
 *
 * ⚠️ 编辑走 postOnce（写操作不重试）；非法表达式服务端返 400 并附支持格式。
 */

import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { cronService, shortDateTime, hasError } from '../services/CronService.ets';
import { CronJobDetail, CronOutput } from '../models/CronModels.ets';
import { rest } from '../core/HermesRest.ets';
import { apiConfig } from '../core/ApiConfig.ets';

@Entry
@Component
struct CronDetailPage {
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State detail: CronJobDetail = new CronJobDetail();
  @State outputs: CronOutput[] = [];
  @State jobId: string = '';

  /** 编辑态 */
  @State editing: boolean = false;
  @State editName: string = '';
  @State editSchedule: string = '';
  @State editPrompt: string = '';
  @State saving: boolean = false;

  /** 展开的历史输出 */
  @State expandedName: string = '';
  @State expandedContent: string = '';
  @State expandedLoading: boolean = false;

  @State busy: boolean = false;

  @StorageLink('apiKey') apiKey: string = '';

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined) {
      this.jobId = (params['jobId'] as string) ?? '';
    }
    this.load();
  }

  private async load(): Promise<void> {
    if (this.jobId.length === 0) {
      this.loading = false;
      this.errorMsg = '缺少任务 ID';
      return;
    }
    this.loading = true;
    this.errorMsg = '';
    try {
      await apiConfig.ensureReady(this.apiKey);
      rest.configure(apiConfig.getBaseUrl(), apiConfig.getApiKey());

      const d: CronJobDetail = await cronService.fetchDetail(this.jobId);
      this.detail = d;
      this.editName = d.name;
      this.editSchedule = d.scheduleExpr.length > 0 ? d.scheduleExpr : d.schedule;
      this.editPrompt = d.prompt;
      this.outputs = await cronService.fetchOutputs(this.jobId);
      this.loading = false;
    } catch (e) {
      this.loading = false;
      this.errorMsg = this.errText(e);
    }
  }

  private async saveEdit(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    try {
      const d: CronJobDetail = await cronService.update(
        this.jobId, this.editName, this.editSchedule, this.editPrompt);
      this.detail = d;
      this.editing = false;
      this.showToast('已保存');
      await this.load();
    } catch (e) {
      const t: string = this.errText(e);
      if (t.indexOf('INVALID_SCHEDULE') >= 0) {
        this.showToast('调度表达式不合法，请检查格式');
      } else if (t.indexOf('NAME_EMPTY') >= 0) {
        this.showToast('名称不能为空');
      } else if (t.indexOf('PROMPT_TOO_LONG') >= 0) {
        this.showToast('提示词过长（上限 50000 字）');
      } else {
        this.showToast('保存失败：' + t);
      }
    } finally {
      this.saving = false;
    }
  }

  private async toggleEnabled(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const r = await cronService.toggle(this.jobId, !this.detail.enabled);
      this.showToast(r.changed ? (r.enabled ? '已启用' : '已暂停') : '状态未变化');
      await this.load();
    } catch (e) {
      this.showToast('操作失败：' + this.errText(e));
    } finally {
      this.busy = false;
    }
  }

  private async runNow(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await cronService.run(this.jobId);
      this.showToast('已触发执行');
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
      this.busy = false;
    }
  }

  private async toggleOutput(o: CronOutput): Promise<void> {
    if (this.expandedName === o.name) {
      this.expandedName = '';
      this.expandedContent = '';
      return;
    }
    this.expandedName = o.name;
    this.expandedContent = '';
    this.expandedLoading = true;
    try {
      this.expandedContent = await cronService.fetchOutputContent(this.jobId, o.name);
    } catch (e) {
      this.expandedContent = '（读取失败：' + this.errText(e) + '）';
    } finally {
      this.expandedLoading = false;
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

  private sizeText(n: number): string {
    if (n >= 1024) {
      return (n / 1024).toFixed(1) + ' KB';
    }
    return String(n) + ' B';
  }

  @Builder
  FieldRow(label: string, value: string, valueColor: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor('#888888')
        .width(84)
      Text(value.length > 0 ? value : '—')
        .fontSize(13)
        .fontColor(valueColor)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 7, bottom: 7 })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  SectionTitle(t: string) {
    Text(t)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor('#5B5BD6')
      .width('100%')
      .margin({ bottom: 4 })
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

          Text('任务详情')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A2E')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)

          Button() {
            Text(this.editing ? '取消' : '编辑').fontSize(15).fontColor('#5B5BD6')
          }
          .backgroundColor('transparent')
          .onClick(() => {
            if (this.editing) {
              this.editing = false;
              this.editName = this.detail.name;
              this.editSchedule = this.detail.scheduleExpr.length > 0
                ? this.detail.scheduleExpr : this.detail.schedule;
              this.editPrompt = this.detail.prompt;
            } else {
              this.editing = true;
            }
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
            Text(this.errorMsg).fontSize(13).fontColor('#999999')
              .margin({ top: 8 }).textAlign(TextAlign.Center)
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
          Scroll() {
            Column() {
              // ── 标题 + 状态 ──
              Column() {
                Text(this.detail.name.length > 0 ? this.detail.name : this.detail.id)
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#1A1A2E')
                  .width('100%')
                Row() {
                  Text(this.detail.enabled ? '● 已启用' : '● 已暂停')
                    .fontSize(12)
                    .fontColor(this.detail.enabled ? '#2E9E6B' : '#C77A20')
                  Text(this.detail.noAgent ? '脚本' : 'Agent')
                    .fontSize(11)
                    .fontColor('#5B5BD6')
                    .backgroundColor('#F0F0FF')
                    .borderRadius(6)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .margin({ left: 10 })
                  Text('投递 ' + this.detail.deliver)
                    .fontSize(11)
                    .fontColor('#AAAAAA')
                    .margin({ left: 10 })
                }
                .width('100%')
                .margin({ top: 8 })
              }
              .width('100%')
              .padding(16)
              .backgroundColor('#FFFFFF')
              .borderRadius(14)
              .alignItems(HorizontalAlign.Start)
              .margin({ bottom: 10 })

              // ── 编辑区 ──
              if (this.editing) {
                Column() {
                  this.SectionTitle('编辑')
                  Text('名称')
                    .fontSize(12).fontColor('#888888').width('100%').margin({ top: 6, bottom: 4 })
                  TextInput({ text: this.editName, placeholder: '任务名称' })
                    .width('100%').height(42)
                    .backgroundColor('#F5F5FA').borderRadius(10)
                    .padding({ left: 12 })
                    .onChange((v: string) => { this.editName = v; })

                  Text('调度表达式')
                    .fontSize(12).fontColor('#888888').width('100%').margin({ top: 12, bottom: 4 })
                  TextInput({ text: this.editSchedule, placeholder: '如 0 9 * * * 或 every 2h' })
                    .width('100%').height(42)
                    .backgroundColor('#F5F5FA').borderRadius(10)
                    .padding({ left: 12 })
                    .onChange((v: string) => { this.editSchedule = v; })

                  Text('支持：cron 表达式（0 9 * * *）· 间隔（every 2h）· 一次性（30m / 2h）\n改动调度后，下次执行时间会自动重算')
                    .fontSize(11)
                    .fontColor('#AAAAAA')
                    .width('100%')
                    .lineHeight(16)
                    .margin({ top: 8 })

                  // ── prompt（只对 Agent 类型有意义）──
                  if (!this.detail.noAgent) {
                    Row() {
                      Text('提示词（Prompt）')
                        .fontSize(12).fontColor('#888888')
                      Blank()
                      Text(this.editPrompt.length + ' 字')
                        .fontSize(11).fontColor('#BBBBBB')
                    }
                    .width('100%')
                    .margin({ top: 14, bottom: 4 })

                    TextArea({ text: this.editPrompt, placeholder: '这个任务每次运行时给 Agent 的指令' })
                      .width('100%')
                      .height(200)
                      .backgroundColor('#F5F5FA')
                      .borderRadius(10)
                      .padding(12)
                      .fontSize(12)
                      .onChange((v: string) => {
                        this.editPrompt = v;
                      })

                    Text('⚠️ 提示词决定任务每次执行做什么，改前请确认内容。留空表示不修改。')
                      .fontSize(11)
                      .fontColor('#C77A20')
                      .width('100%')
                      .lineHeight(16)
                      .margin({ top: 6 })
                  } else {
                    Text('该任务是脚本类型，直接执行 ' + this.detail.script + '，没有提示词。')
                      .fontSize(11)
                      .fontColor('#AAAAAA')
                      .width('100%')
                      .margin({ top: 10 })
                  }

                  Button() {
                    Text(this.saving ? '保存中…' : '保存')
                      .fontSize(15).fontColor('#FFFFFF')
                  }
                  .width('100%').height(44)
                  .backgroundColor(this.saving ? '#9999CC' : '#5B5BD6')
                  .borderRadius(22)
                  .margin({ top: 14 })
                  .enabled(!this.saving)
                  .onClick(() => {
                    this.saveEdit();
                  })
                }
                .width('100%')
                .padding(16)
                .backgroundColor('#FFFFFF')
                .borderRadius(14)
                .alignItems(HorizontalAlign.Start)
                .margin({ bottom: 10 })
              }

              // ── 调度与执行 ──
              Column() {
                this.SectionTitle('调度与执行')
                this.FieldRow('调度', this.detail.schedule, '#1A1A2E')
                this.FieldRow('下次执行', shortDateTime(this.detail.nextRunAt), '#1A1A2E')
                this.FieldRow('上次执行', shortDateTime(this.detail.lastRunAt),
                  this.detail.lastRunAt.length > 0 ? '#1A1A2E' : '#AAAAAA')
                this.FieldRow('上次结果',
                  this.detail.lastStatus.length > 0 ? this.detail.lastStatus : '（未执行过）',
                  this.detail.lastStatus === 'ok' ? '#2E9E6B'
                    : (hasError(this.detail) ? '#D93025' : '#AAAAAA'))
                this.FieldRow('已执行次数', String(this.detail.repeatCompleted) + ' 次', '#1A1A2E')
                this.FieldRow('创建时间', shortDateTime(this.detail.createdAt), '#888888')
                this.FieldRow('任务 ID', this.detail.id, '#888888')

                if (this.detail.pausedAt.length > 0) {
                  this.FieldRow('暂停于', shortDateTime(this.detail.pausedAt), '#C77A20')
                }

                if (hasError(this.detail) && this.detail.lastError.length > 0) {
                  Text('错误详情')
                    .fontSize(12).fontColor('#D93025')
                    .width('100%').margin({ top: 10, bottom: 4 })
                  Scroll() {
                    Text(this.detail.lastError)
                      .fontSize(11)
                      .fontColor('#D93025')
                      .fontFamily('Courier')
                      .lineHeight(16)
                      .width('100%')
                  }
                  .width('100%')
                  .constraintSize({ maxHeight: 140 })
                  .padding(10)
                  .backgroundColor('#FFF5F5')
                  .borderRadius(8)
                }

                // 操作按钮
                Row() {
                  Button() {
                    Text(this.detail.enabled ? '暂停' : '启用')
                      .fontSize(14)
                      .fontColor(this.detail.enabled ? '#C77A20' : '#2E9E6B')
                  }
                  .layoutWeight(1).height(40)
                  .backgroundColor(this.detail.enabled ? '#FFF8ED' : '#F0FFF5')
                  .borderRadius(20)
                  .margin({ right: 6 })
                  .enabled(!this.busy)
                  .onClick(() => {
                    this.toggleEnabled();
                  })

                  Button() {
                    Text(this.busy ? '处理中…' : '立即执行')
                      .fontSize(14)
                      .fontColor(this.detail.enabled ? '#FFFFFF' : '#BBBBBB')
                  }
                  .layoutWeight(1).height(40)
                  .backgroundColor(this.detail.enabled ? '#5B5BD6' : '#EEEEF5')
                  .borderRadius(20)
                  .margin({ left: 6 })
                  .enabled(this.detail.enabled && !this.busy)
                  .onClick(() => {
                    this.runNow();
                  })
                }
                .width('100%')
                .margin({ top: 14 })
              }
              .width('100%')
              .padding(16)
              .backgroundColor('#FFFFFF')
              .borderRadius(14)
              .alignItems(HorizontalAlign.Start)
              .margin({ bottom: 10 })

              // ── 任务内容 ──
              Column() {
                this.SectionTitle('任务内容')
                if (this.detail.noAgent) {
                  this.FieldRow('执行脚本', this.detail.script, '#1A1A2E')
                  Text('该任务直接执行脚本，不经过 Agent。')
                    .fontSize(11).fontColor('#AAAAAA').width('100%').margin({ top: 6 })
                } else if (this.detail.prompt.length > 0) {
                  Text('提示词（Prompt）')
                    .fontSize(12).fontColor('#888888').width('100%').margin({ top: 4, bottom: 6 })
                  Scroll() {
                    Text(this.detail.prompt)
                      .fontSize(12)
                      .fontColor('#333333')
                      .lineHeight(19)
                      .width('100%')
                  }
                  .width('100%')
                  .constraintSize({ maxHeight: 300 })
                  .padding(12)
                  .backgroundColor('#F8F8FC')
                  .borderRadius(8)
                } else {
                  Text('（无内容）').fontSize(12).fontColor('#AAAAAA')
                }

                if (this.detail.skills.length > 0) {
                  this.FieldRow('关联技能', this.detail.skills.join(', '), '#5B5BD6')
                }
                if (this.detail.model !== undefined && this.detail.model.length > 0) {
                  this.FieldRow('指定模型', this.detail.model, '#888888')
                }
              }
              .width('100%')
              .padding(16)
              .backgroundColor('#FFFFFF')
              .borderRadius(14)
              .alignItems(HorizontalAlign.Start)
              .margin({ bottom: 10 })

              // ── 运行历史 ──
              Column() {
                Row() {
                  this.SectionTitle('运行历史')
                  Blank()
                  Text(this.outputs.length + ' 条')
                    .fontSize(11).fontColor('#AAAAAA')
                }
                .width('100%')

                if (this.outputs.length === 0) {
                  Text('还没有运行记录（output 目录为空）')
                    .fontSize(12).fontColor('#AAAAAA').width('100%').margin({ top: 6 })
                } else {
                  ForEach(this.outputs, (o: CronOutput, idx: number) => {
                    Column() {
                      Row() {
                        Text(o.name.replace('.md', ''))
                          .fontSize(13)
                          .fontColor('#1A1A2E')
                          .layoutWeight(1)
                        Text(this.sizeText(o.size))
                          .fontSize(11)
                          .fontColor('#AAAAAA')
                        Text(this.expandedName === o.name ? '  ▲' : '  ▼')
                          .fontSize(11)
                          .fontColor('#5B5BD6')
                      }
                      .width('100%')
                      .padding({ top: 9, bottom: 9 })
                      .onClick(() => {
                        this.toggleOutput(o);
                      })

                      if (this.expandedName === o.name) {
                        if (this.expandedLoading) {
                          Row() {
                            LoadingProgress().width(16).height(16).color('#5B5BD6')
                            Text('读取中…').fontSize(11).fontColor('#999999').margin({ left: 8 })
                          }
                          .width('100%')
                          .padding({ top: 6, bottom: 10 })
                        } else {
                          Scroll() {
                            Text(this.expandedContent)
                              .fontSize(11)
                              .fontColor('#444444')
                              .lineHeight(17)
                              .width('100%')
                          }
                          .width('100%')
                          .constraintSize({ maxHeight: 320 })
                          .padding(10)
                          .backgroundColor('#F8F8FC')
                          .borderRadius(8)
                          .margin({ bottom: 10 })
                        }
                      }
                    }
                    .width('100%')
                    .border({ width: { bottom: 1 }, color: '#EEEEF5' })
                  }, (o: CronOutput) => o.name)
                }
              }
              .width('100%')
              .padding(16)
              .backgroundColor('#FFFFFF')
              .borderRadius(14)
              .alignItems(HorizontalAlign.Start)
              .margin({ bottom: 24 })
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
      .backgroundColor('#F5F5FA')
    }
    .width('100%')
    .height('100%')
  }
}
