/**
 * SessionsPage —— 会话列表（抽屉式）
 *
 * S12 新增。此前 session_id 固定 = device_id，APP 永远只有一个会话，
 * 也没法回看历史会话；本页补齐「列表 + 切换 + 新建」。
 *
 * 切换机制：
 *   选中会话 -> 写 AppStorage['activeSessionId'] -> router.back()
 *   ChatPage 用 @StorageLink 监听该值，变化时重载消息并切换发送目标。
 *   （不直接在页面间传引用的原因：ChatPage 是常驻的入口页，而列表页是临时压栈的）
 *
 * 新建会话 = 把 activeSessionId 置空，由服务端在下次 chat 时生成 `app-{uuid}`
 * 并通过 chat_started 回执 —— APP 收到后写回 AppStorage。
 */

import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { sessionService, relativeTime } from '../services/SessionService.ets';
import { SessionItem } from '../models/SessionModels.ets';
import { rest } from '../core/HermesRest.ets';
import { apiConfig } from '../core/ApiConfig.ets';

/** AppStorage key：当前活跃会话（ChatPage 用 @StorageLink 绑定）*/
export const ACTIVE_SESSION_KEY: string = 'activeSessionId';

const PAGE_SIZE: number = 30;

@Entry
@Component
struct SessionsPage {
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State errorMsg: string = '';
  @State items: SessionItem[] = [];
  @State total: number = 0;
  @State hasMore: boolean = false;

  @StorageLink('apiKey') apiKey: string = '';
  @StorageLink('activeSessionId') activeSessionId: string = '';

  /**
   * S14：长按弹层。
   *
   * ⚠️ 自绘而不用 ActionSheet / AlertDialog / @CustomDialog —— 这三者的对象字面量
   *    参数会被 ArkTS 编译器拒绝（10605038 未类型化对象字面量 / 10605093 字面量内用 this）。
   * ⚠️ 用一个字符串状态而不是三个布尔 —— 三者互斥，单状态天然不会同时展开两层。
   *    layer: '' = 无 / 'menu' = 操作菜单 / 'rename' = 改名 / 'delete' = 删除确认
   */
  @State layer: string = '';
  @State renameText: string = '';
  private menuTarget: SessionItem | null = null;

  private targetTitle(): string {
    return this.menuTarget !== null ? this.menuTarget.displayTitle() : '';
  }

  private showMenu(s: SessionItem): void {
    this.menuTarget = s;
    this.layer = 'menu';
  }

  private openRename(s: SessionItem): void {
    this.menuTarget = s;
    this.renameText = s.displayTitle();
    this.layer = 'rename';
  }

  private openDelete(s: SessionItem): void {
    this.menuTarget = s;
    this.layer = 'delete';
  }

  private closeLayer(): void {
    this.layer = '';
  }

  /** 保存新名字（S14）*/
  private async doRename(title: string): Promise<void> {
    const s: SessionItem | null = this.menuTarget;
    const t: string = title.trim();
    if (s === null || t.length === 0) {
      this.closeLayer();
      return;
    }
    const ok: boolean = await sessionService.rename(s.id, t);
    this.closeLayer();
    if (ok) {
      s.title = t;
      this.items = this.items.slice();   // 换数组引用触发刷新
      promptAction.showToast({ message: '已重命名' });
    } else {
      promptAction.showToast({ message: '重命名失败，请重试' });
    }
  }

  /** 删除会话（S14，服务端软删除）*/
  private async doDelete(s: SessionItem): Promise<void> {
    const ok: boolean = await sessionService.remove(s.id);
    this.closeLayer();
    if (!ok) {
      promptAction.showToast({ message: '删除失败，请重试' });
      return;
    }
    this.items = this.items.filter((it: SessionItem) => it.id !== s.id);
    if (this.total > 0) {
      this.total = this.total - 1;
    }
    promptAction.showToast({ message: '已删除' });
    // 删的正好是当前会话 → 切回默认会话，避免停留在一个已隐藏的会话上
    if (this.activeSessionId === s.id) {
      AppStorage.setOrCreate(ACTIVE_SESSION_KEY, '');
    }
  }


  aboutToAppear(): void {
    this.load(true);
  }

  private async load(reset: boolean): Promise<void> {
    if (reset) {
      this.loading = true;
      this.errorMsg = '';
    } else {
      if (!this.hasMore || this.loadingMore) {
        return;
      }
      this.loadingMore = true;
    }
    try {
      await apiConfig.ensureReady(this.apiKey);
      rest.configure(apiConfig.getBaseUrl(), apiConfig.getApiKey());

      const offset: number = reset ? 0 : this.items.length;
      const page = await sessionService.fetchSessions(PAGE_SIZE, offset);
      this.total = page.total;
      this.hasMore = page.hasMore;
      if (reset) {
        this.items = page.items;
      } else {
        const merged: SessionItem[] = [];
        for (const x of this.items) {
          merged.push(x);
        }
        for (const x of page.items) {
          merged.push(x);
        }
        this.items = merged;
      }
      this.loading = false;
      this.loadingMore = false;
    } catch (e) {
      this.loading = false;
      this.loadingMore = false;
      this.errorMsg = e instanceof Error ? (e as Error).message : String(e);
      this.showToast('加载失败：' + this.errorMsg);
    }
  }

  /** 选中某个会话 -> 写 AppStorage -> 返回聊天页 */
  private pick(s: SessionItem): void {
    if (this.activeSessionId === s.id) {
      this.showToast('已经是当前会话');
      router.back();
      return;
    }
    AppStorage.setOrCreate(ACTIVE_SESSION_KEY, s.id);
    this.showToast('已切换到：' + s.displayTitle());
    router.back();
  }

  /** 新会话：置空，由服务端在下次发消息时生成 ID */
  private newSession(): void {
    AppStorage.setOrCreate(ACTIVE_SESSION_KEY, '');
    this.showToast('已开新会话，发消息即可');
    router.back();
  }

  private showToast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 2000 });
    } catch (err) {
      console.error('toast failed');
    }
  }

  private tokenText(n: number): string {
    if (n >= 10000) {
      return (n / 10000).toFixed(1) + ' 万';
    }
    return String(n);
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

          Text('会话')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A2E')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)

          Button() {
            Text('新会话').fontSize(15).fontColor('#5B5BD6')
          }
          .backgroundColor('transparent')
          .onClick(() => {
            this.newSession();
          })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 8, bottom: 8 })
        .backgroundColor('#F8F9FF')

        // 当前会话提示条
        Row() {
          Text('当前：')
            .fontSize(11).fontColor('#999999')
          Text(this.activeSessionId.length > 0 ? this.activeSessionId : '（新会话，尚未开始）')
            .fontSize(11)
            .fontColor(this.activeSessionId.length > 0 ? '#5B5BD6' : '#C77A20')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
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
            Text(this.errorMsg).fontSize(13).fontColor('#999999')
              .margin({ top: 8 }).textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
            Button() {
              Text('重试').fontSize(14).fontColor('#FFFFFF')
            }
            .width(120).height(40).backgroundColor('#5B5BD6').borderRadius(20)
            .margin({ top: 16 })
            .onClick(() => {
              this.load(true);
            })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.items.length === 0) {
          Column() {
            Text('💬').fontSize(44)
            Text('还没有会话').fontSize(14).fontColor('#999999').margin({ top: 10 })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          List() {
            ForEach(this.items, (s: SessionItem, idx: number) => {
              ListItem() {
                Row() {
                  // 当前会话左侧竖条
                  Column()
                    .width(3)
                    .height(38)
                    .borderRadius(2)
                    .backgroundColor(this.activeSessionId === s.id ? '#5B5BD6' : '#00000000')
                    .margin({ right: 10 })

                  Column() {
                    Text(s.displayTitle())
                      .fontSize(14)
                      .fontWeight(this.activeSessionId === s.id ? FontWeight.Bold : FontWeight.Normal)
                      .fontColor(this.activeSessionId === s.id ? '#5B5BD6' : '#1A1A2E')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')

                    Row() {
                      Text(s.messageCount + ' 条消息')
                        .fontSize(11).fontColor('#AAAAAA')
                      Text('·')
                        .fontSize(11).fontColor('#DDDDDD').margin({ left: 4, right: 4 })
                      Text(this.tokenText(s.tokens) + ' tokens')
                        .fontSize(11).fontColor('#AAAAAA')
                      Blank()
                      Text(relativeTime(s.updatedAt))
                        .fontSize(11).fontColor('#BBBBBB')
                    }
                    .width('100%')
                    .margin({ top: 5 })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  // S14：显式菜单入口。
                  // ⚠️ 长按也能弹（LongPressGesture），但手势既不好发现、自动化也测不到
                  //    （uitest longClick 打不中），所以必须给一个看得见的按钮。
                  Text('⋯')
                    .fontSize(22)
                    .fontColor('#999999')
                    .width(44)
                    .textAlign(TextAlign.Center)
                    .onClick(() => {
                      this.showMenu(s);
                    })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .backgroundColor(idx % 2 === 0 ? '#FFFFFF' : '#F7F8FC')
                .onClick(() => {
                  this.pick(s);
                })
                .gesture(
                  LongPressGesture()
                    .onAction(() => {
                      this.showMenu(s);
                    })
                )
              }
            }, (s: SessionItem) => s.id)

            // 分页加载
            if (this.hasMore) {
              ListItem() {
                Column() {
                  LoadingProgress().width(22).height(22).color('#5B5BD6')
                  Text('加载更多…').fontSize(12).fontColor('#999999').margin({ top: 6 })
                }
                .width('100%')
                .padding({ top: 14, bottom: 14 })
                .onClick(() => {
                  this.load(false);
                })
              }
            }
          }
          .width('100%')
          .layoutWeight(1)
          .divider({ strokeWidth: 1, color: '#EEEEF5' })
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
          .onReachEnd(() => {
            this.load(false);
          })
        }

        Text('共 ' + this.total + ' 个会话' + (this.hasMore ? '（已加载 ' + this.items.length + '）' : ''))
          .fontSize(11)
          .fontColor('#BBBBBB')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 8, bottom: 12 })
          .backgroundColor('#F5F5FA')
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F5F5FA')

      // ─── S14：自绘浮层（单状态驱动，不用系统弹窗 API）───
      if (this.layer.length > 0) {
        Column() {
          Column() {
            Text(this.targetTitle())
              .fontSize(13)
              .fontColor('#888888')
              .maxLines(1)
              .margin({ bottom: 12 })

            if (this.layer === 'menu') {
              Button('重命名')
                .width('100%')
                .height(46)
                .backgroundColor('#F0F1F5')
                .fontColor('#1A1A2E')
                .onClick(() => {
                  if (this.menuTarget !== null) { this.openRename(this.menuTarget); }
                })
              Button('删除会话')
                .width('100%')
                .height(46)
                .margin({ top: 8 })
                .backgroundColor('#FDECEC')
                .fontColor('#E5484D')
                .onClick(() => {
                  if (this.menuTarget !== null) { this.openDelete(this.menuTarget); }
                })
            }

            if (this.layer === 'rename') {
              TextInput({ text: this.renameText, placeholder: '输入新名字' })
                .fontSize(15)
                .maxLength(60)
                .onChange((v: string) => { this.renameText = v; })
              Button('保存')
                .width('100%')
                .height(44)
                .margin({ top: 12 })
                .backgroundColor('#5B5BD6')
                .fontColor('#FFFFFF')
                .onClick(() => { this.doRename(this.renameText); })
            }

            if (this.layer === 'delete') {
              Text('将从列表中移除。服务端只标记隐藏，聊天记录不会真删，可恢复。')
                .fontSize(13)
                .fontColor('#666666')
                .margin({ bottom: 14 })
              Button('确认删除')
                .width('100%')
                .height(44)
                .backgroundColor('#E5484D')
                .fontColor('#FFFFFF')
                .onClick(() => {
                  if (this.menuTarget !== null) { this.doDelete(this.menuTarget); }
                })
            }

            Button('取消')
              .width('100%')
              .height(44)
              .margin({ top: 8 })
              .backgroundColor('#F0F1F5')
              .fontColor('#555555')
              .onClick(() => { this.closeLayer(); })
          }
          .width('80%')
          .padding(16)
          .backgroundColor('#FFFFFF')
          .borderRadius(14)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#66000000')
      }
    }
    .width('100%')
    .height('100%')
  }
}
