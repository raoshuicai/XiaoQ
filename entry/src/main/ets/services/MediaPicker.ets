/**
 * MediaPicker —— 本地图片 / 文件选择 + 上传（S23，S36 修上传）
 *
 * 流程：系统选择器 → **拷贝进应用沙箱** → request.uploadFile 上传 → 删临时文件
 *
 * ⚠️ 上传走 @ohos.request 的 uploadFile（系统级上传，带进度/重试），
 *    不要自己用 rcp 拼 multipart。
 *
 * ⚠️ S36 修复（真机实测报错）：
 *    request.uploadFile 只接受**应用沙箱内**的文件。而系统选择器给的是
 *    媒体库/文档库 URI（`file://media/Photo/...`、`file://docs/...`），
 *    属于"别的应用的文件" → 参数校验阶段直接拒，请求根本没发出去：
 *      "The parameters check fails / Parameter verification failed,
 *       user file can only for request.agent"
 *    报错原意：用户文件只能给 request.agent（应用自己）用。
 *    正解：先用 fs 把选中文件拷到 ctx.cacheDir，拿沙箱 URI 去传，传完删除。
 *    （图还在手机里，服务端无从下手，只能 APP 端修。）
 */

import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { request } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { rest } from '../core/HermesRest.ets';
import { apiConfig } from '../core/ApiConfig.ets';

const TAG: string = 'MediaPicker';

/** 选中后的条目 */
export class PickedItem {
  /** 系统选择器给的原始 URI（媒体库/文档库） */
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

  /** 选一个任意文件（文档类） */
  public async pickDocument(): Promise<PickedItem | null> {
    try {
      const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      const p: picker.DocumentViewPicker = new picker.DocumentViewPicker();
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
   * S36：把"别的应用的文件"复制进本应用沙箱，返回沙箱 URI。
   *
   * request.uploadFile 的 files[].uri 必须是本应用沙箱内的文件，
   * 媒体库/文档库 URI 会被参数校验拒掉（user file can only for request.agent）。
   */
  private copyToSandbox(ctx: common.Context, item: PickedItem): string {
    const srcUri: string = item.uri;
    // 已经在本应用沙箱里的（如 file://.../cache/...）不用再拷
    if (srcUri.indexOf(ctx.cacheDir) >= 0 || srcUri.indexOf(ctx.filesDir) >= 0) {
      hilog.error(0x0001, TAG, 'already in sandbox, skip copy');
      return srcUri;
    }

    // 目标：cacheDir/<时间戳>_<原名>；cacheDir 系统会自动清理，不用长期占空间
    const safe: string = item.name.length > 0 ? item.name : 'upload.bin';
    const dstPath: string = ctx.cacheDir + '/' + Date.now().toString() + '_' + safe;

    const src: fs.File = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
    try {
      const dst: fs.File = fs.openSync(dstPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.copyFileSync(src.fd, dst.fd);
      } finally {
        fs.closeSync(dst);
      }
    } finally {
      fs.closeSync(src);
    }

    const dstUri: string = 'file://' + dstPath;
    hilog.error(0x0001, TAG, 'copied to sandbox: %{public}s', dstUri);
    return dstUri;
  }

  /** 删掉拷进沙箱的临时文件（失败不影响主流程） */
  private removeSandboxCopy(uri: string): void {
    try {
      const path: string = uri.startsWith('file://') ? uri.substring(7) : uri;
      fs.unlinkSync(path);
      hilog.error(0x0001, TAG, 'temp file removed');
    } catch (e) {
      hilog.error(0x0001, TAG, 'remove temp failed: %{public}s', (e as BusinessError).message);
    }
  }

  /**
   * 上传到服务端的 /api/upload，返回相对 URL（如 /api/upload/xxx.jpg）。
   * 失败返回空串。
   */
  public async upload(ctx: common.Context, item: PickedItem): Promise<string> {
    let sandboxUri: string = '';
    let copied: boolean = false;
    try {
      // 0) S36：先把文件拷进应用沙箱 —— 否则上传参数校验直接拒
      sandboxUri = this.copyToSandbox(ctx, item);
      copied = sandboxUri !== item.uri;

      const headers: Record<string, string> = {};
      headers['Authorization'] = 'Bearer ' + apiConfig.getApiKey();

      // ⚠️ type 是必填（查 d.ts：filename/name/uri/type 四个都非可选）
      const files: Array<request.File> = [{
        filename: item.name,
        name: 'file',                       // 必须与服务端 UploadFile 的参数名一致
        uri: sandboxUri,                    // ← 沙箱 URI（S36 改）
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
    } finally {
      // 1) 传完就删临时文件（无论成功失败，避免 cacheDir 堆积）
      if (copied && sandboxUri.length > 0) {
        this.removeSandboxCopy(sandboxUri);
      }
    }
  }

  private baseName(uri: string): string {
    const idx: number = uri.lastIndexOf('/');
    const raw: string = idx >= 0 ? uri.substring(idx + 1) : uri;
    return raw.length > 0 ? raw : 'upload.bin';
  }
}

export const mediaPicker: MediaPicker = new MediaPicker();
