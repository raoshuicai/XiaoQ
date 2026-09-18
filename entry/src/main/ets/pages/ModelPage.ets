/**
 * ModelPage —— 模型切换
 *
 * S13 新增。此前想换模型只能改 Hermes 的 config.yaml。
 *
 * ⚠️ 生效时机 = **下一次对话**（服务端不动正在进行的流），页面明确提示这一点。
 * ⚠️ 切换失败时**回滚 UI 选中态**（验收要求）：先乐观高亮目标项，失败则还原。
 */

import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { discoveryService } from '../services/DiscoveryService.ets';
import { ModelItem } from '../models/DiscoveryModels.ets';
import { rest } from '../core/HermesRest.ets';
import { apiConfig } from '../core/ApiConfig.ets';

@Entry
@Component
struct ModelPage {
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State items: ModelItem[] = [];
  @State busyId: string = '';
  /** 乐观选中的模型（切换中/已切换），失败会回滚 */
  @State pendingId: string = '';
  @State currentId: string = '';

  @StorageLink('apiKey') apiKey: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    try {
      await apiConfig.ensureReady(this.apiKey);
      rest.configure(apiConfig.getBaseUrl(), apiConfig.getApiKey());
      const list: ModelItem[] = await discoveryService.fetchModels();
      this.items = list;
      this.pendingId = '';
      this.currentId = '';
      for (const m of list) {
        if (m.current) {
          this.currentId = m.id;
          break;
        }
      }
      this.loading = false;
    } catch (e) {
      this.loading = false;
      this.errorMsg = e instanceof Error ? (e as Error).message : String(e);
    }
  }

  private async doSwitch(m: ModelItem): Promise<void> {
    if (this.busyId.length > 0) {
      return;
    }
    if (m.id === this.currentId && this.pendingId.length === 0) {
      this.showToast('已经是当前模型');
      return;
    }
    const prevId: string = this.currentId;
    // 乐观更新：先高亮目标，失败再回滚
    this.pendingId = m.id;
    this.busyId = m.id;

    try {
      const r = await discoveryService.switchModel(m.id);
      this.currentId = r.id;
      this.pendingId = '';
      this.showToast('已切换到 ' + r.id + '（下次对话生效）');
      await this.load();
    } catch (e) {
      // 回滚
      this.pendingId = '';
      this.currentId = prevId;
      const t: string = e instanceof Error ? (e as Error).message : String(e);
      if (t.indexOf('MODEL_NOT_FOUND') >= 0) {
        this.showToast('服务端不认识这个模型');
      } else {
        this.showToast('切换失败：' + t);
      }
      await this.load();
    } finally {
      this.busyId = '';
    }
  }

  private showToast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 2500 });
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

          Text('模型')
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

        Text('当前模型：' + (this.currentId.length > 0 ? this.currentId : '—') + ' · 切换后下一次对话生效')
          .fontSize(11)
          .fontColor('#5B5BD6')
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
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
              .margin({ top: 8 }).textAlign(TextAlign.Center).padding({ left: 32, right: 32 })
            Button() {
              Text('重试').fontSize(14).fontColor('#FFFFFF')
            }
            .width(120).height(40).backgroundColor('#5B5BD6').borderRadius(20)
            .margin({ top: 16 })
            .onClick(() => { this.load(); })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          List() {
            ForEach(this.items, (m: ModelItem, idx: number) => {
              ListItem() {
                Row() {
                  Column() {
                    Text(m.name)
                      .fontSize(15)
                      .fontWeight(m.id === this.currentId ? FontWeight.Bold : FontWeight.Normal)
                      .fontColor(m.id === this.currentId ? '#5B5BD6' : '#1A1A2E')
                      .width('100%')
                    Row() {
                      Text(m.provider)
                        .fontSize(11)
                        .fontColor('#888888')
                        .backgroundColor('#F0F0F5')
                        .borderRadius(6)
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      Text(m.id)
                        .fontSize(11)
                        .fontColor('#BBBBBB')
                        .margin({ left: 8 })
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .width('100%')
                    .margin({ top: 6 })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  if (this.busyId === m.id) {
                    LoadingProgress().width(20).height(20).color('#5B5BD6')
                  } else if (m.id === this.currentId) {
                    Text('✓ 使用中')
                      .fontSize(11)
                      .fontColor('#2E9E6B')
                  } else {
                    Text('切换')
                      .fontSize(12)
                      .fontColor('#5B5BD6')
                  }
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 14, bottom: 14 })
                .backgroundColor(idx % 2 === 0 ? '#FFFFFF' : '#F7F8FC')
                .onClick(() => {
                  this.doSwitch(m);
                })
              }
            }, (m: ModelItem) => m.provider + '_' + m.id)
          }
          .width('100%')
          .layoutWeight(1)
          .divider({ strokeWidth: 1, color: '#EEEEF5' })
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
        }

        Text('共 ' + this.items.length + ' 个可用模型 · 来自 Hermes 配置里实际使用过的模型')
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
    }
    .width('100%')
    .height('100%')
  }
}
