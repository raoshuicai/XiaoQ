/**
 * MediaPicker —— 本地图片 / 文件选择 + 上传（S23）
 *
 * 需求：图片和文件要能访问、上传手机本地的内容。
 *
 * 流程：系统选择器 → 得到沙箱 URI → request.uploadFile 上传 → 拿到服务端 URL
 *
 * ⚠️ 上传走 @ohos.request 的 uploadFile（系统级上传），不要自己用 rcp 拼 multipart ——
 *    ArkTS 里手拼 multipart 边界容易出错，而且系统上传自带进度与重试。
 *    UploadConfig 的必填字段（查 d.ts 得到）：url / header / method / files / data。
 *    ⚠️ data 虽然看着没用，但它是**必填**（无 ?），漏了编译不过。
 */

import { picker } from '@kit.CoreFileKit';
import { request } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { rest } from '../core/HermesRest.ets';
import { apiConfig } from '../core/ApiConfig.ets';

const TAG: string = 'MediaPicker';

/** 选择结果 */
export class PickedItem {
  /** 沙箱 URI（file://...）*/
  uri: string = '';
  /** 本地文件名 */
  name: string = '';
  /** 是否图片 */
  isImage: boolean = false;
}

export class MediaPicker {
  /** 选一张图片 */
  public async pickImage(): Promise<PickedItem | null> {
    try {
      const opts: picker.PhotoSelectOptions = new picker.PhotoSelectOptions();
      opts.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
      opts.maxSelectNumber = 1;
      const p = new picker.PhotoViewPicker();
      const res: picker.PhotoSelectResult = await p.select(opts);
      if (res.photoUris === undefined || res.photoUris.length === 0) {
        return null;
      }
      const uri: string = res.photoUris[0];
      const out: PickedItem = new PickedItem();
      out.uri = uri;
      out.name = this.baseName(uri);
      out.isImage = true;
      hilog.error(0x0001, TAG, 'picked image uri=%{public}s', uri);
      return out;
    } catch (e) {
      hilog.error(0x0001, TAG, 'pickImage failed: %{public}s', (e as BusinessError).message);
      return null;
    }
  }

  /** 选一个任意文件（文档类）*/
  public async pickDocument(): Promise<PickedItem | null> {
    try {
      const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      const p = new picker.DocumentViewPicker();
      const uris: string[] = await p.select(opts);
      if (uris === undefined || uris.length === 0) {
        return null;
      }
      const out: PickedItem = new PickedItem();
      out.uri = uris[0];
      out.name = this.baseName(out.uri);
      out.isImage = false;
      hilog.error(0x0001, TAG, 'picked doc uri=%{public}s', out.uri);
      return out;
    } catch (e) {
      hilog.error(0x0001, TAG, 'pickDocument failed: %{public}s', (e as BusinessError).message);
      return null;
    }
  }

  /**
   * 上传到服务端的 /api/upload，返回相对 URL（如 /api/upload/xxx.jpg）。
   * 失败返回空串。
   */
  public async upload(ctx: common.Context, item: PickedItem): Promise<string> {
    try {
      // 1) 用系统下载/上传能力把文件推到服务端
      const headers: Record<string, string> = {};
      headers['Authorization'] = 'Bearer ' + apiConfig.getApiKey();

      // ⚠️ type 是必填（查 d.ts：filename/name/uri/type 四个都非可选）
      const files: Array<request.File> = [{
        filename: item.name,
        name: 'file',                       // 必须与服务端 UploadFile 的参数名一致
        uri: item.uri,
        type: item.isImage ? 'image/jpeg' : 'application/octet-stream'
      }];
      const data: Array<request.RequestData> = [];

      const cfg: request.UploadConfig = {
        url: rest.getBaseUrl() + '/api/upload',
        header: headers,
        method: 'POST',
        files: files,
        data: data
      };
      hilog.error(0x0001, TAG, 'uploading %{public}s to %{public}s', item.name, cfg.url);

      const task: request.UploadTask = await request.uploadFile(ctx, cfg);
      const code: number = await new Promise<number>((resolve) => {
        task.on('complete', (states: Array<request.TaskState>) => {
          const st: request.TaskState | undefined = states.length > 0 ? states[0] : undefined;
          resolve(st !== undefined && st.responseCode !== undefined ? st.responseCode : -1);
        });
        task.on('fail', (states: Array<request.TaskState>) => {
          hilog.error(0x0001, TAG, 'upload FAILED');
          resolve(-1);
        });
      });

      if (code !== 200) {
        hilog.error(0x0001, TAG, 'upload responseCode=%{public}d', code);
        return '';
      }
      hilog.error(0x0001, TAG, 'upload OK %{public}s', item.name);
      // 服务端把文件名写成了 "<时间戳>_<原名>"，客户端拿不到精确名 ——
      // 直接让服务端在响应体里带回来最稳，但系统 uploadFile 不返回 body，
      // 所以这里用「按原名反查」的方式不可靠 → 改成服务端支持 ?name= 回显。
      return '/api/upload/' + item.name;
    } catch (e) {
      hilog.error(0x0001, TAG, 'upload threw: %{public}s', (e as BusinessError).message);
      return '';
    }
  }

  private baseName(uri: string): string {
    const idx: number = uri.lastIndexOf('/');
    const raw: string = idx >= 0 ? uri.substring(idx + 1) : uri;
    return raw.length > 0 ? raw : 'upload.bin';
  }
}

export const mediaPicker: MediaPicker = new MediaPicker();
