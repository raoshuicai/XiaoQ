import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { wifiManager } from '@kit.ConnectivityKit';
import { FileApi, FileItem, FileListResult } from '../utils/FileApi.ets';

const NAV_KEY_VAULT: string = 'vault';
const HOME_WIFI_SSID: string = 'HUAWEI-404';
const LOCAL_FILE_API: string = 'http://192.168.3.87:8866';
const PUBLIC_FILE_API: string = 'https://xiaoq.xiao-q.com';

interface NavItem {
  name: string;
  path: string;
  key: string;
}

@Entry
@Component
struct FilesPage {
  @State currentItems: FileItem[] = [];
  @State isLoading: boolean = true;
  @State currentPath: string = '';
  @State navStack: NavItem[] = [];
  @State titleText: string = '小Q 知识库';
  @StorageLink('apiKey') apiKey: string = '';

  private fileApi: FileApi = new FileApi('', '');

  aboutToAppear(): void {
    // 确定API地址
    this.detectFilesApiUrl().then((apiUrl: string) => {
      this.fileApi.updateConfig(apiUrl, this.apiKey);
      this.navStack = [{ name: '知识库', path: '', key: NAV_KEY_VAULT }];
      this.loadDir('');
    });
  }

  private async detectFilesApiUrl(): Promise<string> {
    // 检测WiFi SSID，家里走本地，外面走公网
    try {
      const linkedInfo: wifiManager.WifiLinkedInfo = await wifiManager.getLinkedInfo();
      if (linkedInfo.ssid === HOME_WIFI_SSID) {
        return LOCAL_FILE_API;
      }
    } catch (error) {
      // 获取失败就走公网
    }
    return PUBLIC_FILE_API;
  }

  private async loadDir(dirPath: string): Promise<void> {
    this.isLoading = true;

    // 先检查API密钥是否已配置
    if (this.apiKey === '') {
      this.showToast('请先在聊天页面 ⚙️ 中配置API密钥');
      this.isLoading = false;
      this.currentItems = [];
      return;
    }

    try {
      const result: FileListResult = await this.fileApi.listFiles(dirPath);
      this.currentItems = result.items;
      this.currentPath = result.path;

      if (dirPath === '') {
        this.titleText = '小Q 知识库';
      } else {
        // 用目录名当标题
        const parts: string[] = dirPath.split('/');
        this.titleText = parts[parts.length - 1];
      }
    } catch (error) {
      let msg: string = '加载失败';
      if (error instanceof Error) {
        msg = (error as Error).message;
      }
      this.showToast(msg);
      this.currentItems = [];
    } finally {
      this.isLoading = false;
    }
  }

  private showToast(message: string): void {
    promptAction.showToast({ message: message });
  }

  private enterDir(item: FileItem): void {
    this.navStack.push({ name: item.name, path: item.path, key: item.path });
    this.loadDir(item.path);
  }

  private goBack(): void {
    if (this.navStack.length <= 1) {
      // 回到聊天
      router.back();
      return;
    }
    this.navStack.pop();
    const prev: NavItem = this.navStack[this.navStack.length - 1];
    this.loadDir(prev.path);
  }

  private openFile(item: FileItem): void {
    const paramObj: Record<string, Object> = {
      'filePath': item.path,
      'fileName': item.name
    };
    router.pushUrl({
      url: 'pages/FileViewPage',
      params: paramObj
    });
  }

  private getFileIcon(item: FileItem): string {
    if (item.type === 'directory') return '📁';
    const name: string = item.name.toLowerCase();
    if (name.endsWith('.md')) return '📝';
    if (name.endsWith('.json') || name.endsWith('.yaml') || name.endsWith('.yml')) return '⚙️';
    if (name.endsWith('.png') || name.endsWith('.jpg') || name.endsWith('.svg')) return '🖼️';
    if (name.endsWith('.py') || name.endsWith('.ts') || name.endsWith('.js')) return '💻';
    if (name.endsWith('.pdf')) return '📄';
    return '📄';
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Button() {
          Text('← ' + (this.navStack.length > 1 ? '返回' : '聊天'))
            .fontSize(15)
            .fontColor('#5B5BD6')
        }
        .backgroundColor('transparent')
        .onClick(() => {
          this.goBack();
        })

        Blank()

        Text(this.titleText)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A2E')

        Blank()

        // 占位保持对称
        Text('')
          .fontSize(15)
          .width(60)
      }
      .width('100%')
      .padding({ left: 8, right: 16, top: 8, bottom: 8 })
      .backgroundColor('#F8F9FF')

      // 面包屑导航
      if (this.navStack.length > 1) {
        Scroll() {
          Row() {
            ForEach(this.navStack, (nav: NavItem, idx: number) => {
              Text((idx > 0 ? ' / ' : '') + nav.name)
                .fontSize(12)
                .fontColor(idx === this.navStack.length - 1 ? '#5B5BD6' : '#999999')
                .onClick(() => {
                  // 点击直接跳转到该层级
                  while (this.navStack.length > idx + 1) {
                    this.navStack.pop();
                  }
                  this.loadDir(nav.path);
                })
            }, (nav: NavItem, idx: number) => nav.key)
          }
          .padding({ left: 16, right: 16, top: 6, bottom: 6 })
        }
        .scrollBar(BarState.Off)
        .height(32)
        .backgroundColor('#F0F0F5')
        .width('100%')
      }

      // 文件列表
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
      } else if (this.currentItems.length === 0) {
        Column() {
          Text('📂')
            .fontSize(48)
          Text('这个目录是空的')
            .fontSize(15)
            .fontColor('#999999')
            .margin({ top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.currentItems, (item: FileItem) => {
            ListItem() {
              Row() {
                Text(this.getFileIcon(item))
                  .fontSize(22)
                  .margin({ right: 12 })

                Column() {
                  Text(item.name)
                    .fontSize(15)
                    .fontColor('#1A1A2E')
                    .lineHeight(22)
                  Text(item.type === 'directory' ? '文件夹' : '文件')
                    .fontSize(11)
                    .fontColor('#BBBBBB')
                    .margin({ top: 2 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Text(item.type === 'directory' ? '›' : '')
                  .fontSize(20)
                  .fontColor('#CCCCCC')
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .backgroundColor('#FFFFFF')
              .borderRadius(10)
              .onClick(() => {
                if (item.type === 'directory') {
                  this.enterDir(item);
                } else {
                  this.openFile(item);
                }
              })
            }
          }, (item: FileItem) => item.path)
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('#F5F5FA')
        .padding({ top: 8, bottom: 8 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5FA')
  }
}
