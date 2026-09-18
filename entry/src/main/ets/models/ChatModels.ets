/**
 * 聊天相关类型定义（纯类型，零逻辑）
 *
 * S1 抽取：分别从 ChatPage / HermesApi / PreferencesHelper 三处搬来。
 *
 * 注意：三个 interface 当前结构完全相同（role + content），保持独立命名
 * 是为了守住 S1「零行为变化」的约束。统一合并留到 S4（ChatService 收口）时做。
 *
 * 本文件不得 import 任何业务代码（见方案 V2 §2.2 分层铁律）。
 */

/** 聊天消息 —— UI 列表项 */
export interface ChatMessage {
  role: string;
  content: string;
}

/** LLM 上下文记录 —— 发请求时构建的历史 */
export interface ChatRecord {
  role: string;
  content: string;
}

/** 本地持久化消息 —— Preferences 读写用 */
export interface StoredMessage {
  role: string;
  content: string;
}
