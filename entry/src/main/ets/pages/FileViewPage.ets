import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { FileApi } from '../utils/FileApi.ets';
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

  private fileApi: FileApi = new FileApi();
  private filePath: string = '';

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
      const content: string = await this.fileApi.readFile(this.filePath);
      this.fileContent = content;
    } catch (error) {
      let msg: string = '读取失败';
      if (error instanceof Error) {
        msg = (error as Error).message;
      }
      this.fileContent = '❌ ' + msg;
      this.showToast(msg);
    } finally {
      this.isLoading = false;
    }
  }

  private showToast(message: string): void {
    promptAction.showToast({ message: message });
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

          Blank()

          Text('')
            .fontSize(15)
            .width(60)
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
