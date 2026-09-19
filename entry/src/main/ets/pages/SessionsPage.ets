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
import { common } from '@kit.AbilityKit';
import { sessionService, relativeTime } from '../services/SessionService.ets';
import { SessionItem } from '../models/SessionModels.ets';
import { saveActiveSessionId } from '../utils/PreferencesHelper.ets';
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

  /**
   * 记住当前会话到持久层（S15）。
   * ⚠️ 只写 AppStorage 不够 —— 那是内存态，APP 重启就丢，启动时会回退到默认会话。
   *    切换会话 / 开新会话（置空）**两个动作都要落盘**，否则重启会回到切之前那个。
   */
  private persistActiveSession(sid: string): void {
    try {
      const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
      saveActiveSessionId(ctx, sid).catch((e: Error) => {
        console.info('persist active session failed: ' + e.message);
      });
    } catch (e) {
      console.info('persist active session skipped');
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
    this.persistActiveSession(s.id);
    this.showToast('已切换到：' + s.displayTitle());
    router.back();
  }

  /** 新会话：置空，由服务端在下次发消息时生成 ID */
  private newSession(): void {
    AppStorage.setOrCreate(ACTIVE_SESSION_KEY, '');
    // ⚠️ 这里**故意不落盘**：开新会话但还没发消息时没有 ID 可存；直接存空串会让
    //    下次启动分不清「没保存过」和「保存了空」。留上次那个真会话即可 ——
    //    一旦发出消息、服务端回执了真实 ID，会由 chat_started 路径落盘。
    this.showToast('已开新会话，发消息即可');
    router.back();
  }

  /** 当前会话的展示名（拿不到标题时回退 ID）*/
  private currentTitle(): string {
    for (const it of this.items) {
      if (it.id === this.activeSessionId) {
        return it.displayTitle();
      }
    }
    return this.activeSessionId;
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
            Text('← 返回').fontSize(15).fontColor($r('app.color.brand'))
          }
          .backgroundColor('transparent')
          .onClick(() => {
            router.back();
          })

          Text('会话')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)

          Button() {
            Text('新会话').fontSize(15).fontColor($r('app.color.brand'))
          }
          .backgroundColor('transparent')
          .onClick(() => {
            this.newSession();
          })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 8, bottom: 8 })
        .backgroundColor($r('app.color.bg_card'))

        // 当前会话提示条
        Row() {
          Text('当前：')
            .fontSize(11).fontColor($r('app.color.text_tertiary'))
          Text(this.activeSessionId.length > 0 ? this.currentTitle() : '（新会话，尚未开始）')
            .fontSize(11)
            .fontColor(this.activeSessionId.length > 0 ? $r('app.color.brand') : $r('app.color.warning'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor($r('app.color.bg_card'))

        if (this.loading) {
          Column() {
            LoadingProgress().width(40).height(40).color($r('app.color.brand'))
            Text('加载中…').fontSize(14).fontColor($r('app.color.text_tertiary')).margin({ top: 10 })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.errorMsg.length > 0) {
          Column() {
            Text('⚠️').fontSize(40)
            Text(this.errorMsg).fontSize(13).fontColor($r('app.color.text_tertiary'))
              .margin({ top: 8 }).textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
            Button() {
              Text('重试').fontSize(14).fontColor($r('app.color.text_on_brand'))
            }
            .width(120).height(40).backgroundColor($r('app.color.brand')).borderRadius(20)
            .margin({ top: 16 })
            .onClick(() => {
              this.load(true);
            })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.items.length === 0) {
          Column() {
            Text('💬').fontSize(44)
            Text('还没有会话').fontSize(14).fontColor($r('app.color.text_tertiary')).margin({ top: 10 })
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
                    .backgroundColor(this.activeSessionId === s.id ? $r('app.color.brand') : '#00000000')
                    .margin({ right: 10 })

                  Column() {
                    Text(s.displayTitle())
                      .fontSize(14)
                      .fontWeight(this.activeSessionId === s.id ? FontWeight.Bold : FontWeight.Normal)
                      .fontColor(this.activeSessionId === s.id ? $r('app.color.brand') : $r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')

                    Row() {
                      Text(s.messageCount + ' 条消息')
                        .fontSize(11).fontColor($r('app.color.text_tertiary'))
                      Text('·')
                        .fontSize(11).fontColor($r('app.color.divider')).margin({ left: 4, right: 4 })
                      Text(this.tokenText(s.tokens) + ' tokens')
                        .fontSize(11).fontColor($r('app.color.text_tertiary'))
                      Blank()
                      Text(relativeTime(s.updatedAt))
                        .fontSize(11).fontColor($r('app.color.text_tertiary'))
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
                    .fontColor($r('app.color.text_tertiary'))
                    .width(44)
                    .textAlign(TextAlign.Center)
                    .onClick(() => {
                      this.showMenu(s);
                    })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .backgroundColor(idx % 2 === 0 ? $r('app.color.text_on_brand') : $r('app.color.bg_page'))
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
            // ⚠️ key 必须包含 title：ForEach 按 key 复用组件，只用 s.id 的话
            //    改名后 id 没变 -> ArkUI 直接复用旧组件 -> 标题文字不更新，
            //    表现为"改完名字不生效，退出重进列表才看到"（实测踩坑）。
            }, (s: SessionItem) => s.id + '|' + s.title)

            // 分页加载
            if (this.hasMore) {
              ListItem() {
                Column() {
                  LoadingProgress().width(22).height(22).color($r('app.color.brand'))
                  Text('加载更多…').fontSize(12).fontColor($r('app.color.text_tertiary')).margin({ top: 6 })
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
          .divider({ strokeWidth: 1, color: $r('app.color.divider') })
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
          .onReachEnd(() => {
            this.load(false);
          })
        }

        Text('共 ' + this.total + ' 个会话' + (this.hasMore ? '（已加载 ' + this.items.length + '）' : ''))
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

      // ─── S14：自绘浮层（单状态驱动，不用系统弹窗 API）───
      if (this.layer.length > 0) {
        Column() {
          Column() {
            Text(this.targetTitle())
              .fontSize(13)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .margin({ bottom: 12 })

            if (this.layer === 'menu') {
              Button('重命名')
                .width('100%')
                .height(46)
                .backgroundColor($r('app.color.bg_input'))
                .fontColor($r('app.color.text_primary'))
                .onClick(() => {
                  if (this.menuTarget !== null) { this.openRename(this.menuTarget); }
                })
              Button('删除会话')
                .width('100%')
                .height(46)
                .margin({ top: 8 })
                .backgroundColor($r('app.color.danger_soft'))
                .fontColor($r('app.color.danger'))
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
                .backgroundColor($r('app.color.brand'))
                .fontColor($r('app.color.text_on_brand'))
                .onClick(() => { this.doRename(this.renameText); })
            }

            if (this.layer === 'delete') {
              Text('将从列表中移除。服务端只标记隐藏，聊天记录不会真删，可恢复。')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .margin({ bottom: 14 })
              Button('确认删除')
                .width('100%')
                .height(44)
                .backgroundColor($r('app.color.danger'))
                .fontColor($r('app.color.text_on_brand'))
                .onClick(() => {
                  if (this.menuTarget !== null) { this.doDelete(this.menuTarget); }
                })
            }

            Button('取消')
              .width('100%')
              .height(44)
              .margin({ top: 8 })
              .backgroundColor($r('app.color.bg_input'))
              .fontColor($r('app.color.text_secondary'))
              .onClick(() => { this.closeLayer(); })
          }
          .width('80%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(14)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.scrim'))
      }
    }
    .width('100%')
    .height('100%')
  }
}
