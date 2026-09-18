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
}
