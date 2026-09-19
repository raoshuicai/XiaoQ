/**
 * FileApi —— 知识库文件接口封装
 *
 * S5 改动：rcp session / 认证头 / 错误处理全部收归 core/HermesRest。
 * 原先这里有一份与 HermesApi 逐行重复的连接样板（同样的 baseAddress 处理、
 * 同样的超时值、同样的 Bearer 拼装）。
 */

import { rest } from '../core/HermesRest.ets';

export interface FileItem {
  type: string;
  name: string;
  path: string;
}

export interface FileListResult {
  path: string;
  items: FileItem[];
}

class FileApiError extends Error {
  constructor(message: string) {
    super(message);
  }
}

export class FileApi {
  /** session 由全局 rest 持有，保留空实现以兼容既有调用点 */
  public destroy(): void {
  }

  public async listFiles(dirPath: string): Promise<FileListResult> {
    if (!rest.isConfigured()) {
      throw new FileApiError('API密钥未配置');
    }
    try {
      const query: Record<string, string> = { 'path': dirPath };
      return await rest.get('/api/files', query) as FileListResult;
    } catch (error) {
      throw new FileApiError(error instanceof Error ? (error as Error).message : String(error));
    }
  }

  public async readFile(filePath: string): Promise<string> {
    if (!rest.isConfigured()) {
      throw new FileApiError('API密钥未配置');
    }
    try {
      const query: Record<string, string> = { 'path': filePath };
      const result: Record<string, Object> = await rest.get('/api/files/read', query) as Record<string, Object>;
      const content: string = result['content'] as string;
      return content !== undefined ? content : '';
    } catch (error) {
      throw new FileApiError(error instanceof Error ? (error as Error).message : String(error));
    }
  }

  /**
   * 读取文件并让服务端渲染成适合手机阅读的 HTML（S17，仅 .md 有效）。
   *
   * ⚠️ 为什么放服务端渲染：Vault 里 **76% 的文档含表格**（实测 429/565），
   *    md 源码里的 `|`、`#`、`**` 直接吐出来没法读；而表格排版（横向滚动、
   *    列宽、斑马纹）交给成熟 CSS 最省事。实测转换耗时中位 3.9ms、90 分位
   *    18.6ms，服务端另有 mtime 缓存，重复打开为 0 开销。
   *
   * 返回 rendered=false（非 md / 老服务端）时调用方应回退纯文本。
   */
  public async readFileRendered(filePath: string): Promise<RenderedFile> {
    if (!rest.isConfigured()) {
      throw new FileApiError('API密钥未配置');
    }
    try {
      const query: Record<string, string> = { 'path': filePath, 'render': 'html' };
      const result: Record<string, Object> = await rest.get('/api/files/read', query) as Record<string, Object>;
      const out: RenderedFile = new RenderedFile();
      out.rendered = result['rendered'] === true;
      const html: string = result['html'] as string;
      const content: string = result['content'] as string;
      out.html = html !== undefined ? html : '';
      // content 用于「复制全文」——服务端在同一次响应里带回来，省一次请求
      out.content = content !== undefined ? content : '';
      return out;
    } catch (error) {
      throw new FileApiError(error instanceof Error ? (error as Error).message : String(error));
    }
  }
}

/** readFileRendered 的返回（ArkTS 禁对象字面量，必须显式类型）*/
export class RenderedFile {
  rendered: boolean = false;
  html: string = '';
  content: string = '';
}
