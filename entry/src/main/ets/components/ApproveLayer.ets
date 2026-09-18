/**
 * ApproveLayer —— 全局审批浮层
 *
 * S7 引入。挂在每个页面根布局的最上层，订阅 ApproveService。
 * 只有「当前前台页面」才会真正渲染卡片（approveService.shouldRender），
 * 所以就算多个页面同时挂着本组件，也不会叠出多张卡片。
 *
 * 两种展示形态：
 *   1. 正常：审批卡片（ApproveSheet），四选项
 *   2. 未配置 apiKey：引导卡片 —— 直接告诉用户「请先配置 API 密钥」并给跳转按钮
 *      （对应 MoA 反馈 3 / S0 发现的「审批可收不可回」缺陷：
 *        原先要点下去才失败，且提示语对用户没有指导意义）
 *
 * ⚠️ 状态刻意拆成基础类型 @State（而不是直接放 ApproveRequest | null）：
 *    ArkTS 在 build() 里对可空类型不够友好，拆开可以彻底避免空断言。
 */

import { ApproveSheet } from './ApproveSheet.ets';
import { ApproveRequest, approveService } from '../services/ApproveService.ets';
import { apiConfig } from '../core/ApiConfig.ets';

@Component
export struct ApproveLayer {
  /** 本页面名（与 ApproveService.setActivePage 登记的保持一致） */
  @Prop pageName: string = '';
  /** 点「去配置」时由宿主页面处理（通常是打开设置面板） */
  onGoSettings: () => void = () => {};
  /** 提交结果回调（宿主页面弹提示语） */
  onResult: (ok: boolean, choice: string) => void = () => {};

  @State hasRequest: boolean = false;
  @State reqRunId: string = '';
  @State reqCommand: string = '';
  @State reqPatterns: string[] = [];
  @State reqDescription: string = '';
  @State reqSessionId: string = '';
  @State reqAt: number = 0;
  @State inProgress: boolean = false;
  @State notConfigured: boolean = false;

  /**
   * S11：这里也要能拿到 apiKey。
   * 页面启动早期的异步链（读设备ID → 读密钥 → 检测网络）要走几秒，期间
   * apiConfig 里可能还没有 key；而审批可能恰好在那一刻到达。
   * 用 @StorageLink 直接读 AppStorage 里的权威值，refresh 时补设一次。
   */
  @StorageLink('apiKey') apiKey: string = '';

  private unsubscribe: (() => void) | null = null;

  aboutToAppear(): void {
    this.unsubscribe = approveService.subscribe((): void => {
      this.refresh();
    });
    this.refresh();
  }

  aboutToDisappear(): void {
    if (this.unsubscribe !== null) {
      this.unsubscribe();
      this.unsubscribe = null;
    }
  }

  private refresh(): void {
    const req: ApproveRequest | null = approveService.getCurrent();
    const visible: boolean = req !== null && approveService.shouldRender(this.pageName);

    if (visible && req !== null) {
      this.hasRequest = true;
      this.reqRunId = req.runId;
      this.reqCommand = req.command;
      this.reqPatterns = req.patterns;
      this.reqDescription = req.description;
      this.reqSessionId = req.sessionId;
      this.reqAt = req.receivedAt;
    } else {
      this.hasRequest = false;
    }
    this.inProgress = approveService.isInProgress();

    // S11：如果 apiConfig 里还没有 key（启动早期），用 AppStorage 的权威值补一次；
    // 否则「未配置密钥」引导卡会误报，且 ApproveService.respond() 会直接失败。
    if (apiConfig.getApiKey().length === 0 && this.apiKey.length > 0) {
      apiConfig.ensureReady(this.apiKey).then(() => {
        this.notConfigured = apiConfig.getApiKey().length === 0;
      }).catch((e: Error) => {
        console.info('approve layer ensureReady failed: ' + e.message);
        this.notConfigured = true;
      });
    } else {
      this.notConfigured = apiConfig.getApiKey().length === 0;
    }
  }

  private async choose(choice: string): Promise<void> {
    const ok: boolean = await approveService.respond(choice);
    this.onResult(ok, choice);
  }

  build() {
    Stack() {
      if (this.hasRequest) {
        if (this.notConfigured) {
          // ── 未配置密钥：引导卡片（不让用户白点） ──
          Column() {
            Column() {
              Row() {
                Text('🔑').fontSize(28).margin({ right: 10 })
                Column() {
                  Text('授权请求').fontSize(12).fontColor('#888888')
                  Text('需要先配置密钥').fontSize(18).fontWeight(FontWeight.Bold)
                    .fontColor('#1A1A2E').lineHeight(24)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .margin({ bottom: 12 })

              Text('小Q 收到一条授权请求，但当前还没有配置 API 密钥，无法提交处理结果。')
                .fontSize(13)
                .fontColor('#666666')
                .lineHeight(20)
                .width('100%')
                .margin({ bottom: 8 })

              if (this.reqCommand.length > 0) {
                Text(this.reqCommand)
                  .fontSize(13)
                  .fontColor('#FFFFFF')
                  .fontFamily('Courier')
                  .lineHeight(20)
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                  .backgroundColor('#1A1A2E')
                  .borderRadius(8)
                  .margin({ bottom: 12 })
              }

              Row() {
                Button() {
                  Text('去配置').fontSize(14).fontColor('#FFFFFF')
                }
                .layoutWeight(1).height(44).backgroundColor('#5B5BD6').borderRadius(10)
                .margin({ right: 6 })
                .onClick(() => {
                  this.onGoSettings();
                })

                Button() {
                  Text('稍后').fontSize(14).fontColor('#666666')
                }
                .layoutWeight(1).height(44).backgroundColor('#F0F0F5').borderRadius(10)
                .margin({ left: 6 })
                .onClick(() => {
                  approveService.dismissCurrent();
                })
              }
              .width('100%')
            }
            .width('100%')
            .padding(24)
            .backgroundColor('#FFFFFF')
            .borderRadius({ topLeft: 20, topRight: 20 })
          }
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .justifyContent(FlexAlign.End)
          .onClick(() => {
            approveService.dismissCurrent();
          })
        } else {
          ApproveSheet({
            command: this.reqCommand,
            patterns: this.reqPatterns,
            description: this.reqDescription,
            sessionId: this.reqSessionId,
            receivedAt: this.reqAt,
            inProgress: this.inProgress,
            onChoice: (choice: string) => {
              this.choose(choice);
            },
            onDismiss: () => {
              approveService.dismissCurrent();
            }
          })
        }
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(this.hasRequest ? HitTestMode.Default : HitTestMode.Transparent)
  }
}
