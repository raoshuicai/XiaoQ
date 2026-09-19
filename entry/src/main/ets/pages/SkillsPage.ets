/**
 * SkillsPage —— 技能浏览 + 记忆查看
 *
 * S13 新增。两块内容放在一个页面用顶部切换，省一个入口（顶部图标位已满）：
 *   技能：237 个技能的列表 + 搜索（对应 `hermes skills list`）
 *   记忆：Agent 的 MEMORY.md 内容（只读）
 */

import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { discoveryService } from '../services/DiscoveryService.ets';
import { SkillItem, MemoryInfo } from '../models/DiscoveryModels.ets';
import { rest } from '../core/HermesRest.ets';
import { apiConfig } from '../core/ApiConfig.ets';

@Entry
@Component
struct SkillsPage {
  @State tab: string = 'skills';       // skills | memory
  @State loading: boolean = true;
  @State errorMsg: string = '';

  @State skills: SkillItem[] = [];
  /** 已展示的数量（客户端分页，避免 237 项一次性全量渲染）*/
  @State shownCount: number = 40;
  @State keyword: string = '';
  @State mem: MemoryInfo = new MemoryInfo();

  /** 当前应渲染的技能（切片）*/
  private visibleSkills(): SkillItem[] {
    if (this.skills.length <= this.shownCount) {
      return this.skills;
    }
    const out: SkillItem[] = [];
    for (let i: number = 0; i < this.shownCount && i < this.skills.length; i++) {
      out.push(this.skills[i]);
    }
    return out;
  }

  private hasMoreSkills(): boolean {
    return this.skills.length > this.shownCount;
  }

  @StorageLink('apiKey') apiKey: string = '';

  aboutToAppear(): void {
    this.loadSkills();
  }

  private async ensureRest(): Promise<void> {
    await apiConfig.ensureReady(this.apiKey);
    rest.configure(apiConfig.getBaseUrl(), apiConfig.getApiKey());
  }

  private async loadSkills(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    this.shownCount = 40;      // 换关键词/刷新后重置分页
    try {
      await this.ensureRest();
      this.skills = await discoveryService.fetchSkills(this.keyword.trim());
      this.loading = false;
    } catch (e) {
      this.loading = false;
      this.errorMsg = e instanceof Error ? (e as Error).message : String(e);
    }
  }

  private async loadMemory(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    try {
      await this.ensureRest();
      this.mem = await discoveryService.fetchMemory();
      this.loading = false;
    } catch (e) {
      this.loading = false;
      this.errorMsg = e instanceof Error ? (e as Error).message : String(e);
    }
  }

  private switchTab(t: string): void {
    if (this.tab === t) {
      return;
    }
    this.tab = t;
    if (t === 'skills') {
      this.loadSkills();
    } else {
      this.loadMemory();
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
            Text('← 返回').fontSize(15).fontColor($r('app.color.brand'))
          }
          .backgroundColor('transparent')
          .onClick(() => {
            router.back();
          })

          Text(this.tab === 'skills' ? '技能' : '记忆')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)

          Button() {
            Text('刷新').fontSize(15).fontColor($r('app.color.brand'))
          }
          .backgroundColor('transparent')
          .onClick(() => {
            if (this.tab === 'skills') {
              this.loadSkills();
            } else {
              this.loadMemory();
            }
          })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 8, bottom: 8 })
        .backgroundColor($r('app.color.bg_card'))

        // 切换
        Row() {
          Text('技能')
            .fontSize(13)
            .fontColor(this.tab === 'skills' ? $r('app.color.text_on_brand') : $r('app.color.text_secondary'))
            .backgroundColor(this.tab === 'skills' ? $r('app.color.brand') : $r('app.color.bg_input'))
            .borderRadius(15)
            .padding({ left: 18, right: 18, top: 6, bottom: 6 })
            .onClick(() => { this.switchTab('skills'); })
          Text('记忆')
            .fontSize(13)
            .fontColor(this.tab === 'memory' ? $r('app.color.text_on_brand') : $r('app.color.text_secondary'))
            .backgroundColor(this.tab === 'memory' ? $r('app.color.brand') : $r('app.color.bg_input'))
            .borderRadius(15)
            .padding({ left: 18, right: 18, top: 6, bottom: 6 })
            .margin({ left: 10 })
            .onClick(() => { this.switchTab('memory'); })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .backgroundColor($r('app.color.bg_card'))

        // 搜索框（只对技能有效）
        if (this.tab === 'skills') {
          Row() {
            TextInput({ placeholder: '搜索技能名或描述…', text: this.keyword })
              .layoutWeight(1)
              .height(40)
              .backgroundColor($r('app.color.bg_page'))
              .borderRadius(20)
              .padding({ left: 14, right: 14 })
              .fontSize(13)
              .onChange((v: string) => {
                this.keyword = v;
              })
              .onSubmit(() => {
                this.loadSkills();
              })
            Button() {
              Text('搜索').fontSize(13).fontColor($r('app.color.text_on_brand'))
            }
            .height(36)
            .backgroundColor($r('app.color.brand'))
            .borderRadius(18)
            .padding({ left: 14, right: 14 })
            .margin({ left: 8 })
            .onClick(() => {
              this.loadSkills();
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 6, bottom: 10 })
          .backgroundColor($r('app.color.bg_card'))
        }

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
              .margin({ top: 8 }).textAlign(TextAlign.Center).padding({ left: 32, right: 32 })
            Button() {
              Text('重试').fontSize(14).fontColor($r('app.color.text_on_brand'))
            }
            .width(120).height(40).backgroundColor($r('app.color.brand')).borderRadius(20)
            .margin({ top: 16 })
            .onClick(() => {
              if (this.tab === 'skills') {
                this.loadSkills();
              } else {
                this.loadMemory();
              }
            })
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.tab === 'skills') {
          if (this.skills.length === 0) {
            Column() {
              Text('🔍').fontSize(44)
              Text(this.keyword.length > 0 ? '没有匹配「' + this.keyword + '」的技能' : '没有技能')
                .fontSize(14).fontColor($r('app.color.text_tertiary')).margin({ top: 10 })
            }
            .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          } else {
            List() {
              ForEach(this.visibleSkills(), (s: SkillItem, idx: number) => {
                ListItem() {
                  Column() {
                    Row() {
                      Text(s.name)
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.text_primary'))
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(s.category)
                        .fontSize(10)
                        .fontColor($r('app.color.brand'))
                        .backgroundColor($r('app.color.brand_soft'))
                        .borderRadius(5)
                        .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                    }
                    .width('100%')

                    if (s.description.length > 0) {
                      Text(s.description)
                        .fontSize(11)
                        .fontColor($r('app.color.text_tertiary'))
                        .lineHeight(16)
                        .maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                        .margin({ top: 5 })
                    }
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 11, bottom: 11 })
                  .backgroundColor(idx % 2 === 0 ? $r('app.color.text_on_brand') : $r('app.color.bg_page'))
                  .alignItems(HorizontalAlign.Start)
                }
              }, (s: SkillItem) => s.category + '/' + s.name)

              // 客户端分页：一次只渲染 40 项，触底再放一批
              if (this.hasMoreSkills()) {
                ListItem() {
                  Text('加载更多（已显示 ' + this.shownCount + ' / ' + this.skills.length + '）')
                    .fontSize(12)
                    .fontColor($r('app.color.brand'))
                    .width('100%')
                    .textAlign(TextAlign.Center)
                    .padding({ top: 14, bottom: 14 })
                    .onClick(() => {
                      this.shownCount = this.shownCount + 40;
                    })
                }
              }
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Auto)
            .edgeEffect(EdgeEffect.Spring)
            .onReachEnd(() => {
              if (this.hasMoreSkills()) {
                this.shownCount = this.shownCount + 40;
              }
            })
          }
        } else {
          Scroll() {
            Column() {
              Text(this.mem.exists
                ? ('MEMORY.md · ' + this.mem.size + ' 字节')
                : '记忆文件不存在')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .margin({ bottom: 10 })

              Text(this.mem.content.length > 0 ? this.mem.content : '（空）')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .lineHeight(19)
                .width('100%')
            }
            .width('100%')
            .padding(16)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
          .backgroundColor($r('app.color.bg_card'))
        }

        if (!this.loading && this.errorMsg.length === 0) {
          Text(this.tab === 'skills'
            ? ('共 ' + this.skills.length + ' 个技能 · 对应 hermes skills list')
            : '只读视图 · 修改记忆请通过对话让 Agent 自己更新')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 8, bottom: 12 })
            .backgroundColor($r('app.color.bg_page'))
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
