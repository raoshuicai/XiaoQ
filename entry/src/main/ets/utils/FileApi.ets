import { rcp } from '@kit.RemoteCommunicationKit';

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
  private baseUrl: string = '';
  private apiKey: string = '';
  private session: rcp.Session | null = null;

  constructor(baseUrl: string, apiKey: string) {
    this.baseUrl = baseUrl;
    this.apiKey = apiKey;
    this.createSession();
  }

  public updateConfig(baseUrl: string, apiKey: string): void {
    this.baseUrl = baseUrl;
    this.apiKey = apiKey;
    this.closeSession();
    this.createSession();
  }

  private createSession(): void {
    try {
      const config: rcp.SessionConfiguration = {
        baseAddress: this.baseUrl.replace(/\/+$/, ''),
        requestConfiguration: {
          transfer: {
            autoRedirect: true,
            timeout: {
              connectMs: 15000,
              transferMs: 120000
            }
          }
        }
      };
      this.session = rcp.createSession(config);
    } catch (error) {
      console.error('FileApi createSession failed');
      this.session = null;
    }
  }

  private closeSession(): void {
    if (this.session !== null) {
      try {
        this.session.close();
      } catch (error) {
        // ignore
      }
      this.session = null;
    }
  }

  public destroy(): void {
    this.closeSession();
  }

  public async listFiles(dirPath: string): Promise<FileListResult> {
    if (this.apiKey === '') {
      throw new FileApiError('API密钥未配置');
    }

    if (this.session === null) {
      this.createSession();
      if (this.session === null) {
        throw new FileApiError('创建网络连接失败');
      }
    }

    try {
      const requestHeaders: Record<string, string> = {
        'Authorization': 'Bearer ' + this.apiKey
      };

      const request: rcp.Request = new rcp.Request(
        '/api/files?path=' + encodeURIComponent(dirPath),
        'GET',
        requestHeaders,
        {}
      );

      const response: rcp.Response = await this.session.fetch(request);
      const statusCode: number = response.statusCode;

      if (statusCode === 200) {
        const result: FileListResult = response.toJSON() as FileListResult;
        return result;
      }
      const errorText: string = response.toString() ?? '请求失败';
      throw new FileApiError('HTTP ' + statusCode + ': ' + errorText);
    } catch (error) {
      if (error instanceof FileApiError) {
        throw error;
      }
      if (error instanceof Error) {
        throw new FileApiError((error as Error).message);
      }
      throw new FileApiError('未知网络错误');
    }
  }

  public async readFile(filePath: string): Promise<string> {
    if (this.apiKey === '') {
      throw new FileApiError('API密钥未配置');
    }

    if (this.session === null) {
      this.createSession();
      if (this.session === null) {
        throw new FileApiError('创建网络连接失败');
      }
    }

    try {
      const requestHeaders: Record<string, string> = {
        'Authorization': 'Bearer ' + this.apiKey
      };

      const request: rcp.Request = new rcp.Request(
        '/api/files/read?path=' + encodeURIComponent(filePath),
        'GET',
        requestHeaders,
        {}
      );

      const response: rcp.Response = await this.session.fetch(request);
      const statusCode: number = response.statusCode;

      if (statusCode === 200) {
        const result: Record<string, Object> = response.toJSON() as Record<string, Object>;
        const content: string = result['content'] as string;
        return content ?? '';
      }
      const errorText: string = response.toString() ?? '读取失败';
      throw new FileApiError('HTTP ' + statusCode + ': ' + errorText);
    } catch (error) {
      if (error instanceof FileApiError) {
        throw error;
      }
      if (error instanceof Error) {
        throw new FileApiError((error as Error).message);
      }
      throw new FileApiError('未知网络错误');
    }
  }
}
