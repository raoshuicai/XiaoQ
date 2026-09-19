import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { webview } from '@kit.ArkWeb';
import { fileIo } from '@kit.CoreFileKit';
import { FileApi, RenderedFile } from '../utils/FileApi.ets';
// S5：网络检测收口到 ApiConfig，REST 客户端收口到 HermesRest
import { apiConfig } from '../core/ApiConfig.ets';
import { rest } from '../core/HermesRest.ets';
// S7：审批全局化 —— 任何页面都能收到审批
import { ApproveLayer } from '../components/ApproveLayer.ets';
import { approveService } from '../services/ApproveService.ets';

@Entry
@Component
struct FileViewPage {
  @State fileContent: string = '';
  @State isLoading: boolean = true;
  @State fileName: string = '';
  @State isMarkdown: boolean = false;
  /**
   * S17：服务端渲染好的 HTML（仅 .md 有值）。
   * 非空 → 用 Web 组件渲染（表格/标题/代码块排版全部交给 CSS，且文本可长按选中复制）；
   * 空     → 回退原来的纯文本渲染（非 md 文件，或服务端没返回 rendered）。
   */
  @State htmlContent: string = '';

  private fileApi: FileApi = new FileApi();
  private filePath: string = '';
  private webCtl: webview.WebviewController = new webview.WebviewController();

  /**
   * S7：登记本页为「审批可展示页」（页面栈里只有前台页面会渲染卡片）
   */
  onPageShow(): void {
    approveService.setActivePage('fileview');
  }

  onPageHide(): void {
    approveService.clearActivePage('fileview');
  }

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined) {
      this.filePath = params['filePath'] as string;
      this.fileName = params['fileName'] as string;
    }

    this.isMarkdown = this.fileName.toLowerCase().endsWith('.md');

    // S5：网络检测收口到 ApiConfig（原先本页也有独立的一份）
    const savedKey: string = AppStorage.get<string>('apiKey') as string;
    apiConfig.ensureReady(savedKey ?? '').then((apiUrl: string) => {
      rest.configure(apiUrl, apiConfig.getApiKey());
      this.loadContent();
    });
  }

  private async loadContent(): Promise<void> {
    this.isLoading = true;
    try {
      // S17：.md 走服务端渲染后的 HTML（阅读排版 + 可选中复制）
      if (this.isMarkdown) {
        const rf: RenderedFile = await this.fileApi.readFileRendered(this.filePath);
        if (rf.rendered && rf.html.length > 0) {
          this.htmlContent = rf.html;
          this.fileContent = rf.content;   // 纯文本留着给「复制全文」用
          return;
        }
        // 服务端没给 rendered（老版本/异常）→ 落到下面的纯文本兜底
        console.info('render=html unavailable, falling back to plain text');
      }
      const content: string = await this.fileApi.readFile(this.filePath);
      this.fileContent = content;
      this.htmlContent = '';
    } catch (error) {
      let msg: string = '读取失败';
      if (error instanceof Error) {
        msg = (error as Error).message;
      }
      this.fileContent = '❌ ' + msg;
      this.htmlContent = '';
      this.showToast(msg);
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 复制全文（S17）。
   *
   * ⚠️ 用户反馈"打开文档没法复制内容"。Web 组件里的文字本身可以长按选中复制
   *    （CSS 里已显式写 `user-select:text`），但长文档逐段选很麻烦 ——
   *    一键复制整篇是阅读场景里更常用的动作。
   */
  private copyAll(): void {
    if (this.fileContent.length === 0) {
      this.showToast('内容还没加载好');
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,
        this.fileContent);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.showToast('已复制全文');
    } catch (e) {
      this.showToast('复制失败');
    }
  }

  private showToast(message: string): void {
    promptAction.showToast({ message: message });
  }

  /**
   * 把 HTML 灌进 Web 组件。
   *
   * ⚠️ 走"写沙箱文件 + loadUrl(file://)"而不是 controller.loadData()：
   *    loadData 在本机实测**完全不渲染**（服务端日志确认 render=html 已 200 返回、
   *    数据也拿到了，但 Web 区域始终白屏；src 给 '' 或 'about:blank' 都一样）。
   *    落盘再 loadUrl 是更可靠的路子，也顺带支持大文档（某些实现里 data: URL 有长度上限）。
   */
  private pushHtml(): void {
    if (this.htmlContent.length === 0) {
      return;
    }
    try {
      const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
      const fp: string = ctx.filesDir + '/doc_preview.html';
      const f: fileIo.File = fileIo.openSync(fp,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, this.htmlContent);
      fileIo.closeSync(f);
      this.webCtl.loadUrl('file://' + fp);
      console.info('[S17] loadUrl file://' + fp + ' len=' + this.htmlContent.length);
    } catch (e) {
      console.info('[S17] pushHtml failed: ' + (e as Error).message);
      // 兜底：落盘失败就直接试着用 loadData
      try {
        this.webCtl.loadData(this.htmlContent, 'text/html', 'UTF-8');
      } catch (e2) {
        console.info('[S17] loadData fallback failed too');
      }
    }
  }

  build() {
    Stack() {
      Column() {
        // 标题栏
        Row() {
          Button() {
            Text('← 返回')
              .fontSize(15)
              .fontColor('#5B5BD6')
          }
          .backgroundColor('transparent')
          .onClick(() => {
            router.back();
          })

          Blank()

          Text(this.fileName)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A2E')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .onClick(() => {
              // 诊断用：点标题显示当前加载状态（html 长度 / 是否渲染模式）
              this.showToast('html=' + this.htmlContent.length + ' text=' + this.fileContent.length
                + (this.isMarkdown ? ' [md]' : ' [txt]'));
            })

          Blank()

          // S17：一键复制全文（Web 渲染时正文本地也有纯文本，见 loadContent）
          Text('复制')
            .fontSize(15)
            .fontColor('#5B5BD6')
            .width(60)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.copyAll();
            })
        }
        .width('100%')
        .padding({ left: 8, right: 16, top: 8, bottom: 8 })
        .backgroundColor('#F8F9FF')

        // 正文
        if (this.isLoading) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
              .color('#5B5BD6')
            Text('加载中...')
              .fontSize(14)
              .fontColor('#999999')
              .margin({ top: 12 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.htmlContent.length > 0) {
          // S17：md → 服务端渲染好的 HTML。
          // ⚠️ 用 loadData 而不是 Web({ src })，因为 src 只接受 URL；
          //    baseUrl/historyUrl 不传，避免 CSS 里的 # 被当作锚点解析（实测坑）。
          // ⚠️ src 给 'about:blank' 而不是 '' —— 空字符串会让 Web 组件不进入可用状态，
          //    onControllerAttached 里灌进去的内容不显示（实测白屏）。
          Web({ src: 'about:blank', controller: this.webCtl })
            .onControllerAttached(() => {
              this.pushHtml();
            })
            .onPageEnd(() => {
              console.info('[S17] web page end, html length=' + this.htmlContent.length);
            })
            .onErrorReceive((e) => {
              if (e !== undefined) {
                console.info('[S17] web error: ' + JSON.stringify(e.error));
              }
            })
            .width('100%')
            .layoutWeight(1)
            .backgroundColor('#FFFFFF')
        } else {
          Scroll() {
            Text(this.fileContent)
              .fontSize(14)
              .fontColor('#333333')
              .lineHeight(24)
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 24 })
          }
          .scrollBar(BarState.Auto)
          .width('100%')
          .layoutWeight(1)
          .backgroundColor('#FFFFFF')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F5F5FA')

      // S7：审批浮层 —— 本页在前台时也能收到审批请求
      ApproveLayer({ pageName: 'fileview' })
    }
    .width('100%')
    .height('100%')
  }
}
