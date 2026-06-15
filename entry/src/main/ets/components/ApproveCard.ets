import { promptAction } from '@kit.ArkUI';

interface ApproveRequest {
  id: string;
  title: string;
  description: string;
  details: string[];
  requester: string;
  timestamp: number;
}

@CustomDialog
export struct ApproveCard {
  @State request: ApproveRequest = {
    id: '',
    title: '',
    description: '',
    details: [],
    requester: '',
    timestamp: 0
  };
  @State isProcessing: boolean = false;

  private onApprove?: () => void;
  private onReject?: () => void;

  public setRequest(req: ApproveRequest): void {
    this.request = req;
  }

  public setCallbacks(onApprove: () => void, onReject: () => void): void {
    this.onApprove = onApprove;
    this.onReject = onReject;
  }

  build() {
    Column() {
      // 头部：授权标识 + 标题
      Row() {
        Text('🔐')
          .fontSize(28)
          .margin({ right: 10 })
        Column() {
          Text('授权请求')
            .fontSize(12)
            .fontColor('#888888')
          Text(this.request.title)
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

      // 请求描述
      Text(this.request.description)
        .fontSize(14)
        .fontColor('#666666')
        .lineHeight(20)
        .width('100%')
        .margin({ bottom: 16 })

      // 详情列表
      Column() {
        ForEach(this.request.details, (detail: string, index: number) => {
          Row() {
            Text('•')
              .fontSize(14)
              .fontColor('#5B5BD6')
              .margin({ right: 8 })
            Text(detail)
              .fontSize(13)
              .fontColor('#444444')
              .lineHeight(18)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .margin({ bottom: 6 })
        }, (detail: string, index: number) => index.toString())
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#F8F9FF')
      .borderRadius(10)
      .margin({ bottom: 16 })

      // 请求者信息
      Row() {
        Text('👤 ' + this.request.requester)
          .fontSize(12)
          .fontColor('#999999')
        Blank()
        Text(new Date(this.request.timestamp).toLocaleString())
          .fontSize(11)
          .fontColor('#BBBBBB')
      }
      .width('100%')
      .margin({ bottom: 20 })

      // 操作按钮
      Row() {
        // 拒绝
        Button() {
          Text('拒绝')
            .fontSize(15)
            .fontColor('#FF4444')
            .fontWeight(FontWeight.Medium)
        }
        .width(120)
        .height(44)
        .backgroundColor('#FFF0F0')
        .borderRadius(22)
        .enabled(!this.isProcessing)
        .onClick(() => {
          this.isProcessing = true;
          if (this.onReject !== null) {
            this.onReject();
          }
        })

        Blank()

        // 同意
        Button() {
          if (this.isProcessing) {
            LoadingProgress()
              .width(20)
              .height(20)
              .color('#FFFFFF')
          } else {
            Text('同意')
              .fontSize(15)
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Bold)
          }
        }
        .width(120)
        .height(44)
        .backgroundColor('#5B5BD6')
        .borderRadius(22)
        .enabled(!this.isProcessing)
        .onClick(() => {
          this.isProcessing = true;
          if (this.onApprove !== null) {
            this.onApprove();
          }
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding(24)
    .backgroundColor('#FFFFFF')
    .borderRadius(20)
  }
}
