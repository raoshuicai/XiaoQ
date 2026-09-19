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
    if (srcUri.startsWith('internal://cache/')) {
      hilog.error(0x0001, TAG, 'already internal://cache, skip copy');
      return srcUri;
    }

    // 目标：cacheDir/<时间戳>_<原名>；cacheDir 系统会自动清理，不用长期占空间
    const safe: string = item.name.length > 0 ? item.name : 'upload.bin';
    const safeName: string = Date.now().toString() + '_' + safe;   // 仅文件名，无目录
    const dstPath: string = ctx.cacheDir + '/' + safeName;

    hilog.error(0x0001, TAG, '[COPY] start src=%{public}s', srcUri);
    hilog.error(0x0001, TAG, '[COPY] dst=%{public}s', dstPath);

    let src: fs.File | undefined = undefined;
    let dst: fs.File | undefined = undefined;
    try {
      src = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
      hilog.error(0x0001, TAG, '[COPY] openSync(src) ok fd=%{public}d', src.fd);

      dst = fs.openSync(dstPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      hilog.error(0x0001, TAG, '[COPY] openSync(dst) ok fd=%{public}d', dst.fd);

      fs.copyFileSync(src.fd, dst.fd);
      hilog.error(0x0001, TAG, '[COPY] copyFileSync ok');
    } catch (e) {
      const be = e as BusinessError;
      hilog.error(0x0001, TAG, '[COPY] FAILED code=%{public}d msg=%{public}s', be.code, be.message);
      // ⚠️ ArkTS 禁止 throw 任意类型（arkts-limited-throw），必须包成 Error
      throw new Error('copy to sandbox failed: ' + be.message);
    } finally {
      if (dst !== undefined) {
        try { fs.closeSync(dst); } catch (x) { /* ignore */ }
      }
      if (src !== undefined) {
        try { fs.closeSync(src); } catch (x) { /* ignore */ }
      }
    }

    // ★ 关键：request.uploadFile 只接受 **internal://cache/<文件名>** 这种内部路径，
    //   给 file:///data/... 会报 "GetInternalPath failed, filePath is not valid"。
    //   internal://cache/ 后面只能是**相对 cacheDir 的文件名**（不带目录）。
    const dstUri: string = 'internal://cache/' + safeName;
    try {
      const st: fs.Stat = fs.statSync(dstPath);
      hilog.error(0x0001, TAG, '[COPY] done uploadUri=%{public}s (real=%{public}s) size=%{public}d',
        dstUri, dstPath, st.size);
    } catch (x) {
      hilog.error(0x0001, TAG, '[COPY] done uploadUri=%{public}s (stat failed)', dstUri);
    }
    return dstUri;
  }

  /** 删掉拷进沙箱的临时文件（失败不影响主流程） */
  private removeSandboxCopy(ctx: common.Context, uri: string): void {
    try {
      let path: string = uri;
      if (uri.startsWith('internal://cache/')) {
        // internal://cache/<文件名> -> <cacheDir>/<文件名>
        path = ctx.cacheDir + '/' + uri.substring('internal://cache/'.length);
      } else if (uri.startsWith('file://')) {
        path = uri.substring(7);
      }
      fs.unlinkSync(path);
      hilog.error(0x0001, TAG, 'temp file removed: %{public}s', path);
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
      hilog.error(0x0001, TAG, 'uploading name=%{public}s uri=%{public}s to %{public}s', item.name, sandboxUri, cfg.url);

      const task: request.UploadTask = await request.uploadFile(ctx, cfg);

      // ⚠️ 不要用 TaskState.responseCode 判断成败：真机实测服务端明明返回 200、
      //    文件也收全了(1.17MB)，它给的值却是 0。官方语义是：
      //      complete 事件触发 = 上传任务完成；fail 事件 = 失败。
      //    所以以**事件类型**为准，responseCode 只打日志当参考。
      // 另外 headerReceive 里能拿到真实响应头，用它兜底记录 HTTP 状态码。
      let httpHint: number = -1;
      const code: number = await new Promise<number>((resolve) => {
        task.on('headerReceive', (header: object) => {
          try {
            const h: Record<string, string> = header as Record<string, string>;
            const raw: string | undefined = h['responseCode'];
            if (raw !== undefined) {
              httpHint = Number(raw);
            }
          } catch (x) {
            // header 结构不确定，忽略
          }
          hilog.error(0x0001, TAG, '[HDR] responseCode hint=%{public}d', httpHint);
        });
        task.on('complete', (states: Array<request.TaskState>) => {
          const st: request.TaskState | undefined = states.length > 0 ? states[0] : undefined;
          const rc: number = st !== undefined && st.responseCode !== undefined ? st.responseCode : -1;
          hilog.error(0x0001, TAG, '[DONE] complete event, rc=%{public}d hint=%{public}d', rc, httpHint);
          resolve(200);                    // ★ complete 即成功
        });
        task.on('fail', (states: Array<request.TaskState>) => {
          const st: request.TaskState | undefined = states.length > 0 ? states[0] : undefined;
          const rc: number = st !== undefined && st.responseCode !== undefined ? st.responseCode : -1;
          hilog.error(0x0001, TAG, 'upload FAILED rc=%{public}d', rc);
          resolve(-1);
        });
      });

      if (code === -1) {
        hilog.error(0x0001, TAG, 'upload failed (fail event)');
        return '';
      }
      hilog.error(0x0001, TAG, 'upload OK %{public}s', item.name);
      // 服务端把文件名写成了 "<时间戳>_<原名>"，客户端拿不到精确名 ——
      // 直接让服务端在响应体里带回来最稳，但系统 uploadFile 不返回 body，
      // 所以这里用「按原名反查」的方式不可靠 → 改成服务端支持 ?name= 回显。
      return '/api/upload/' + item.name;
    } catch (e) {
      const be = e as BusinessError;
      // ⚠️ 一定要打 code：uploadFile 的参数校验失败和网络失败 message 很像，
      //    只有 code 能区分（1300002/401 等）
      hilog.error(0x0001, TAG, 'upload threw code=%{public}d msg=%{public}s', be.code, be.message);
      return '';
    } finally {
      // 1) 传完就删临时文件（无论成功失败，避免 cacheDir 堆积）
      if (copied && sandboxUri.length > 0) {
        this.removeSandboxCopy(ctx, sandboxUri);
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
