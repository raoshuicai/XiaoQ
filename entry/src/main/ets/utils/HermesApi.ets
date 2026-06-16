import { rcp } from '@kit.RemoteCommunicationKit';

export interface ChatMessage {
  role: string;
  content: string;
}

class HermesError extends Error {
  constructor(message: string) {
    super(message);
  }
}

export class HermesApi {
  private baseUrl: string = '';
  private apiKey: string = '';
  private sessionId: string = '';
  private session: rcp.Session | null = null;

  constructor(baseUrl: string, apiKey: string) {
    this.baseUrl = baseUrl;
    this.apiKey = apiKey;
    this.sessionId = 'harmony-' + Date.now().toString() + '-' + Math.random().toString(36).substring(2, 10);
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
      console.error('createSession failed');
      this.session = null;
    }
  }

  private closeSession(): void {
    if (this.session !== null) {
      try {
        this.session.close();
      } catch (error) {
        // ignore close errors
      }
      this.session = null;
    }
  }

  public destroy(): void {
    this.closeSession();
  }

  public async sendMessage(messageList: ChatMessage[]): Promise<string> {
    if (this.baseUrl === '' || this.apiKey === '') {
      throw new HermesError('请在设置中配置API地址和密钥');
    }

    if (this.session === null) {
      this.createSession();
      if (this.session === null) {
        throw new HermesError('创建网络连接失败');
      }
    }

    const bodyObj: Record<string, Object> = {
      'model': 'current',
      'stream': false,
      'messages': messageList
    };

    try {
      const requestHeaders: Record<string, string> = {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + this.apiKey,
        'X-Hermes-Session-Id': this.sessionId
      };

      const request: rcp.Request = new rcp.Request(
        '/v1/chat/completions',
        'POST',
        requestHeaders,
        bodyObj
      );

      const response: rcp.Response = await this.session.fetch(request);
      const statusCode: number = response.statusCode;

      if (statusCode === 200) {
        const result: Record<string, Object> = response.toJSON() as Record<string, Object>;
        const choices: Object[] = result['choices'] as Object[];
        if (choices.length > 0) {
          const choiceObj: Record<string, Object> = choices[0] as Record<string, Object>;
          const messageObj: Record<string, Object> = choiceObj['message'] as Record<string, Object>;
          const content: string = messageObj['content'] as string;
          if (content !== undefined) {
            return content;
          }
        }
        return '收到回复，但解析失败';
      }
      const errorText: string = response.toString() ?? '请求失败';
      throw new HermesError('HTTP ' + statusCode + ': ' + errorText);
    } catch (error) {
      if (error instanceof HermesError) {
        throw error;
      }
      if (error instanceof Error) {
        throw new HermesError((error as Error).message);
      }
      throw new HermesError('未知网络错误');
    }
  }

  /**
   * 对 Hermes 运行授权请求做出响应
   */
  public async approveRun(runId: string, approval: string): Promise<void> {
    if (this.baseUrl === '' || this.apiKey === '') {
      throw new HermesError('未配置API地址或密钥');
    }
    if (this.session === null) {
      this.createSession();
      if (this.session === null) {
        throw new HermesError('创建网络连接失败');
      }
    }

    try {
      const requestHeaders: Record<string, string> = {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + this.apiKey
      };
      const bodyObj: Record<string, Object> = {
        'approval': approval
      };
      const request: rcp.Request = new rcp.Request(
        '/v1/runs/' + encodeURIComponent(runId) + '/approval',
        'POST',
        requestHeaders,
        bodyObj
      );
      const response: rcp.Response = await this.session.fetch(request);
      if (response.statusCode !== 200) {
        console.error('approveRun failed: HTTP ' + response.statusCode);
      }
    } catch (error) {
      console.error('approveRun error: ' + error);
      if (error instanceof HermesError) {
        throw error;
      }
      throw new HermesError(String(error));
    }
  }
}
