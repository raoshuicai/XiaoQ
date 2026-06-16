import { promptAction } from '@kit.ArkUI';

@CustomDialog
export struct ApproveCard {
  @State titleText: string = '';
  @State descriptionText: string = '';
  @State runId: string = '';
  @State isProcessing: boolean = false;
  @State commandText: string = '';
  @State patternKeys: string[] = [];

  private onChoice?: (choice: string) => void;

  public setData(runId: string, title: string, description: string, command: string, patterns: string[]): void {
    this.runId = runId;
    this.titleText = title;
    this.descriptionText = description;
    this.commandText = command;
    this.patternKeys = patterns;
  }

  public setCallbacks(onChoice: (choice: string) => void): void {
    this.onChoice = onChoice;
  }

  private choose(choice: string): void {
    if (this.isProcessing) {
      return;
    }
    this.isProcessing = true;
    if (this.onChoice !== undefined) {
      this.onChoice(choice);
    }
  }

  private getLabel(choice: string): string {
    const labels: Record<string, string> = {
      'once': '仅本次放行',
      'session': '本次会话放行',
      'always': '始终允许',
      'deny': '拒绝'
    };
    return labels[choice] ?? choice;
  }

  private getIcon(choice: string): string {
    const icons: Record<string, string> = {
      'once': '▶️',
      'session': '🔄',
      'always': '✅',
      'deny': '⛔'
    };
    return icons[choice] ?? '•';
  }

  build() {
    Column() {
      // 头部
      Row() {
        Text('🔐')
          .fontSize(28)
          .margin({ right: 10 })
        Column() {
          Text('授权请求')
            .fontSize(12)
            .fontColor('#888888')
          Text(this.titleText)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A2E')
            .lineHeight(24)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .margin({ bottom: 16 })

      // 命令内容（代码风格展示）
      if (this.commandText.length > 0) {
        Text('需要执行的命令：')
          .fontSize(13)
          .fontColor('#888888')
          .width('100%')
          .margin({ bottom: 6 })
        Text(this.commandText)
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

      // 描述
      if (this.descriptionText.length > 0) {
        Text(this.descriptionText)
          .fontSize(14)
          .fontColor('#666666')
          .lineHeight(20)
          .width('100%')
          .margin({ bottom: 12 })
      }

      // 匹配的模式
      if (this.patternKeys.length > 0) {
        Wrap() {
          ForEach(this.patternKeys, (pattern: string) => {
            Text(pattern)
              .fontSize(11)
              .fontColor('#5B5BD6')
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor('#F0F0FF')
              .borderRadius(10)
              .margin({ right: 4, bottom: 4 })
          })
        }
        .width('100%')
        .margin({ bottom: 16 })
      }

      // 四个操作按钮
      Column() {
        // 第一行：批准本次 / 批准会话
        Row() {
          Button() {
            Row() {
              Text('▶️')
                .fontSize(14)
              Text('仅本次放行')
                .fontSize(13)
                .fontColor('#1A1A2E')
                .margin({ left: 4 })
            }
            .justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1)
          .height(44)
          .backgroundColor('#F0F5FF')
          .borderRadius(10)
          .margin({ right: 6 })
          .enabled(!this.isProcessing)
          .onClick(() => { this.choose('once'); })

          Button() {
            Row() {
              Text('🔄')
                .fontSize(14)
              Text('会话放行')
                .fontSize(13)
                .fontColor('#1A1A2E')
                .margin({ left: 4 })
            }
            .justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1)
          .height(44)
          .backgroundColor('#F0FFF0')
          .borderRadius(10)
          .margin({ left: 6 })
          .enabled(!this.isProcessing)
          .onClick(() => { this.choose('session'); })
        }
        .width('100%')
        .margin({ bottom: 8 })

        // 第二行：始终允许 / 拒绝
        Row() {
          Button() {
            Row() {
              Text('✅')
                .fontSize(14)
              Text('始终允许')
                .fontSize(13)
                .fontColor('#FFFFFF')
                .margin({ left: 4 })
            }
            .justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1)
          .height(44)
          .backgroundColor('#4CAF50')
          .borderRadius(10)
          .margin({ right: 6 })
          .enabled(!this.isProcessing)
          .onClick(() => { this.choose('always'); })

          Button() {
            Row() {
              Text('⛔')
                .fontSize(14)
              Text('拒绝')
                .fontSize(13)
                .fontColor('#FFFFFF')
                .margin({ left: 4 })
            }
            .justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1)
          .height(44)
          .backgroundColor('#FF5252')
          .borderRadius(10)
          .margin({ left: 6 })
          .enabled(!this.isProcessing)
          .onClick(() => { this.choose('deny'); })
        }
        .width('100%')
      }
      .width('100%')

      // 处理中指示
      if (this.isProcessing) {
        Row() {
          LoadingProgress()
            .width(16)
            .height(16)
            .color('#5B5BD6')
          Text('处理中...')
            .fontSize(13)
            .fontColor('#999999')
            .margin({ left: 8 })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 12 })
      }
    }
    .width('100%')
    .padding(24)
    .backgroundColor('#FFFFFF')
    .borderRadius(20)
  }
}
