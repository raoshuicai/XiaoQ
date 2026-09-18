/**
 * NotifyPage —— 通知中心
 *
 * S9 新增。此前服务端的通知只能靠 WS 推送当场落进聊天流，翻不回去、
 * 也不知道自己有多少没看。本页把「读 + 已读 + 未读计数」补齐。
 *
 * 交互取舍：
 *   - 进页面**不自动全部标已读**（用户可能想逐条看），提供「全部已读」按钮
 *   - 未读行左侧有蓝点 + 标题加粗，已读行整行降低对比度
 *   - 列表行式 + 交替底色（既定界面偏好）
 */

import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { notifyService, shortTime, badgeText } from '../services/NotifyService.ets';
import { PushMessage } from '../models/NotifyModels.ets';
import { rest } from '../core/HermesRest.ets';
import { apiConfig } from '../core/ApiConfig.ets';

@Entry
@Component
struct NotifyPage {
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State items: PushMessage[] = [];
  @State unreadOnly: boolean = false;
  @State busy: boolean = false;

  @StorageLink('apiKey') apiKey: string = '';
  @StorageLink('unreadCount') unreadCount: number = 0;

  aboutToAppear(): void {
    this.load();
  }

  onPageShow(): void {
    // 从别处返回时刷新（期间可能有新通知）
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    try {
      await apiConfig.ensureReady(this.apiKey);
      rest.configure(apiConfig.getBaseUrl(), apiConfig.getApiKey());

      this.items = await notifyService.fetchMessages(100, this.unreadOnly);
      await notifyService.refreshUnread();
      this.loading = false;
    } catch (e) {
      this.loading = false;
      this.errorMsg = e instanceof Error ? (e as Error).message : String(e);
      this.showToast('加载失败：' + this.errorMsg);
    }
  }

  private async markAll(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const n: number = await notifyService.markAllRead();
      this.showToast(n > 0 ? '已全部标记为已读' : '没有未读通知');
      await this.load();
    } catch (e) {
      this.showToast('操作失败：' + (e instanceof Error ? (e as Error).message : String(e)));
    } finally {
      this.busy = false;
    }
  }

  private async markOne(m: PushMessage): Promise<void> {
    if (m.readAt.length > 0 || this.busy) {
      return;
    }
    this.busy = true;
    try {
      await notifyService.markRead([m.id]);
      await this.load();
    } catch (e) {
      this.showToast('标记失败');
    } finally {
      this.busy = false;
    }
  }

  private showToast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 2000 });
    } catch (err) {
      console.error('toast failed');
    }
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

          Text(this.unreadOnly ? '未读通知' : '通知中心')
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

        // 工具行：未读筛选 + 全部已读
        Row() {
          Row() {
            Checkbox()
              .select(this.unreadOnly)
              .selectedColor('#5B5BD6')
              .width(18)
              .height(18)
              .onChange((v: boolean) => {
                this.unreadOnly = v;
                this.load();
              })
            Text('只看未读')
              .fontSize(13)
              .fontColor('#666666')
              .margin({ left: 6 })
          }
          .layoutWeight(1)

          Text(badgeText(this.unreadCount).length > 0
            ? ('未读 ' + badgeText(this.unreadCount))
            : '全部已读')
            .fontSize(13)
            .fontColor(this.unreadCount > 0 ? '#FF6B35' : '#AAAAAA')
            .margin({ right: 12 })

          Button() {
            Text(this.busy ? '处理中…' : '全部已读')
              .fontSize(13)
              .fontColor('#FFFFFF')
          }
          .height(32)
          .backgroundColor(this.busy || this.unreadCount === 0 ? '#BBBBCC' : '#5B5BD6')
          .borderRadius(16)
          .enabled(!this.busy && this.unreadCount > 0)
          .onClick(() => {
            this.markAll();
          })
        }
        .width('100%')
        .padding({ left: 16, right: 12, top: 8, bottom: 8 })
        .backgroundColor('#FFFFFF')

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
        } else if (this.items.length === 0) {
          Column() {
            Text('📭').fontSize(48)
            Text(this.unreadOnly ? '没有未读通知' : '还没有通知')
              .fontSize(15).fontColor('#999999').margin({ top: 8 })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          List() {
            ForEach(this.items, (m: PushMessage, idx: number) => {
              ListItem() {
                Row() {
                  // 未读蓝点
                  Column()
                    .width(8)
                    .height(8)
                    .borderRadius(4)
                    .backgroundColor(m.readAt.length === 0 ? '#5B5BD6' : '#00000000')
                    .margin({ top: 6, right: 8 })

                  Column() {
                    Row() {
                      Text(m.title.length > 0 ? m.title : '(无标题)')
                        .fontSize(14)
                        .fontWeight(m.readAt.length === 0 ? FontWeight.Bold : FontWeight.Normal)
                        .fontColor(m.readAt.length === 0 ? '#1A1A2E' : '#999999')
                        .layoutWeight(1)
                      Text(shortTime(m.createdAt))
                        .fontSize(11)
                        .fontColor('#BBBBBB')
                    }
                    .width('100%')

                    Text(m.body)
                      .fontSize(13)
                      .fontColor(m.readAt.length === 0 ? '#555555' : '#AAAAAA')
                      .lineHeight(19)
                      .maxLines(4)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                      .margin({ top: 4 })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .backgroundColor(idx % 2 === 0 ? '#FFFFFF' : '#F7F8FC')
                .alignItems(VerticalAlign.Top)
                .onClick(() => {
                  this.markOne(m);
                })
              }
            }, (m: PushMessage) => String(m.id))
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)

          Text('点击某条即标记为已读 · 共 ' + this.items.length + ' 条')
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
