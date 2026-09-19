import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
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
  /** S17：内容是否已灌进 Web（onPageEnd 会重复触发，用它保证只灌一次）*/
  private htmlLoaded: boolean = false;
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
   * ⚠️ 必须传满 5 个参数（后两个给空格）—— 这是本功能最关键的一行：
   *    loadData(data, mimeType, encoding, baseUrl?, historyUrl?)
   *    baseUrl 缺省时，HTML 里 CSS 的 `#` 颜色值（#333 / #fff 等）会被当作
   *    URL 的 fragment 解析 → 样式崩掉 → **整个 Web 区域白屏，且完全不报错**。
   *    我们的 HTML 是自带 <style> 的完整文档（必然含大量 `#`），所以必须传。
   *
   * ⚠️ 曾经走过弯路：改成"写沙箱文件 + loadUrl('file://')"依然白屏 ——
   *    因为问题不在加载方式，而在 `#` 的解析歧义（file:// 下同样存在），
   *    而且那条路还额外引入 fileAccess 权限等变量。已回退。
   */
  private pushHtml(): void {
    if (this.htmlContent.length === 0) {
      hilog.error(0x0001, 'S17', 'pushHtml: htmlContent is EMPTY, nothing to load');
      return;
    }
    try {
      // 诊断：把实际要加载的内容长度与前 80 字符记进 hilog（console.info 不进日志）
      hilog.error(0x0001, 'S17', 'loadData len=%{public}d head=%{public}s',
        this.htmlContent.length, this.htmlContent.substring(0, 80));
      this.webCtl.loadData(this.htmlContent, 'text/html', 'UTF-8', ' ', ' ');
    } catch (e) {
      hilog.error(0x0001, 'S17', 'loadData THREW: %{public}s', (e as Error).message);
      this.showToast('文档渲染失败');
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
              .fontColor($r('app.color.brand'))
          }
          .backgroundColor('transparent')
          .onClick(() => {
            router.back();
          })

          Blank()

          Text(this.fileName)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .onClick(() => {
              this.showToast(this.fileName);
            })

          Blank()

          // S17：一键复制全文（Web 渲染时正文本地也有纯文本，见 loadContent）
          Text('复制')
            .fontSize(15)
            .fontColor($r('app.color.brand'))
            .width(60)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.copyAll();
            })
        }
        .width('100%')
        .padding({ left: 8, right: 16, top: 8, bottom: 8 })
        .backgroundColor($r('app.color.bg_card'))

        // 正文
        if (this.isLoading) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
              .color($r('app.color.brand'))
            Text('加载中...')
              .fontSize(14)
              .fontColor($r('app.color.text_tertiary'))
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
            .onPageEnd(() => {
              // ⚠️ 真正的根因在这里：**不能在 onControllerAttached 里 loadData**。
              //    那一刻 Web 尚未准备好接收内容，loadData 会被**静默丢弃**（无报错、无异常，
              //    表现为白屏）。实测对比：同样的调用放在这里就正常，放在 onControllerAttached 就白屏。
              //    ⚠️ onPageEnd 会重复触发（about:blank 加载完一次、loadData 内容加载完又一次），
              //    必须用标志位保证只灌一次，否则会自激循环。
              if (!this.htmlLoaded && this.htmlContent.length > 0) {
                this.htmlLoaded = true;
                this.pushHtml();
              }
              hilog.error(0x0001, 'S17', 'onPageEnd htmlLoaded=%{public}s len=%{public}d',
                String(this.htmlLoaded), this.htmlContent.length);
            })
            .onErrorReceive((e) => {
              if (e !== undefined) {
                hilog.error(0x0001, 'S17', 'onErrorReceive: %{public}s',
                  JSON.stringify(e.error));
              }
            })
            .width('100%')
            .layoutWeight(1)
            .backgroundColor($r('app.color.bg_card'))
        } else {
          Scroll() {
            Text(this.fileContent)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .lineHeight(24)
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 24 })
          }
          .scrollBar(BarState.Auto)
          .width('100%')
          .layoutWeight(1)
          .backgroundColor($r('app.color.bg_card'))
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      // S7：审批浮层 —— 本页在前台时也能收到审批请求
      ApproveLayer({ pageName: 'fileview' })
    }
    .width('100%')
    .height('100%')
  }
}
