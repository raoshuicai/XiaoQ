/**
 * HermesApi —— Hermes Gateway 接口封装
 *
 * S5 改动：rcp session / 认证头 / 错误处理全部收归 core/HermesRest，
 * 本类只保留业务语义（聊天补全的响应解析、审批路径拼装）。
 *
 * ⚠️ 路径提醒（施工时最容易搞混的一处）：
 *   - 聊天补全：POST /v1/chat/completions
 *   - 审批响应：POST /v1/runs/{runId}/approval   ← 不是 chat/completions
 */

import { ChatMessage } from '../models/ChatModels.ets';
import { rest } from '../core/HermesRest.ets';

class HermesError extends Error {
  constructor(message: string) {
    super(message);
  }
}

export class HermesApi {
  private sessionId: string = '';

  constructor(baseUrl: string, apiKey: string) {
    this.sessionId = 'harmony-' + Date.now().toString() + '-' + Math.random().toString(36).substring(2, 10);
    rest.configure(baseUrl, apiKey);
  }

  public updateConfig(baseUrl: string, apiKey: string): void {
    rest.configure(baseUrl, apiKey);
  }

  /** session 由全局 rest 持有，这里保留空实现以兼容既有调用点 */
  public destroy(): void {
  }

  /**
   * 非流式聊天补全（当前链路实际走 WebSocket 流式；
   * 本方法保留给"一次性问答"类调用）。
   */
  public async sendMessage(messageList: ChatMessage[]): Promise<string> {
    if (!rest.isConfigured()) {
      throw new HermesError('请在设置中配置API地址和密钥');
    }

    const bodyObj: Record<string, Object> = {
      'model': 'current',
      'stream': false,
      'messages': messageList
    };
    const extraHeaders: Record<string, string> = {
      'X-Hermes-Session-Id': this.sessionId
    };

    try {
      const result: Record<string, Object> = await rest.post(
        '/v1/chat/completions', bodyObj, extraHeaders) as Record<string, Object>;

      const choices: Object[] = result['choices'] as Object[];
      if (choices !== undefined && choices.length > 0) {
        const choiceObj: Record<string, Object> = choices[0] as Record<string, Object>;
        const messageObj: Record<string, Object> = choiceObj['message'] as Record<string, Object>;
        const content: string = messageObj['content'] as string;
        if (content !== undefined) {
          return content;
        }
      }
      return '收到回复，但解析失败';
    } catch (error) {
      throw new HermesError(error instanceof Error ? (error as Error).message : String(error));
    }
  }

  /**
   * 对 Hermes 运行授权请求做出响应。
   * ⚠️ 用 postOnce（不重试）—— 审批是有副作用的提交，重试可能造成重复响应。
   */
  public async approveRun(runId: string, approval: string): Promise<void> {
    if (!rest.isConfigured()) {
      throw new HermesError('未配置API地址或密钥');
    }

    const bodyObj: Record<string, Object> = {
      'approval': approval
    };

    try {
      await rest.postOnce('/v1/runs/' + encodeURIComponent(runId) + '/approval', bodyObj);
    } catch (error) {
      console.error('approveRun failed: ' + error);
      throw new HermesError(error instanceof Error ? (error as Error).message : String(error));
    }
  }
}
