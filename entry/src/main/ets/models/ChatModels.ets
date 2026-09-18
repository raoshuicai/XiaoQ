/**
 * 聊天相关类型定义（纯类型，零逻辑）
 *
 * S1 抽取：分别从 ChatPage / HermesApi / PreferencesHelper 三处搬来。
 * S4：ChatMessage 增加可选字段 msg_id（迁移时补写 + 后续多会话合并去重）。
 *
 * 注意：三个 interface 当前结构相同，保持独立命名是为了守住「零行为变化」的
 * 迁移节奏；统一合并留到后续步骤。
 *
 * 本文件不得 import 任何业务代码（见方案 V2 §2.2 分层铁律）。
 */

/** 聊天消息 —— UI 列表项 */
export interface ChatMessage {
  role: string;
  content: string;
  /** S4：消息唯一标识。旧数据没有此字段，迁移时按"索引+时间戳"补写 */
  msg_id?: string;
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
  msg_id?: string;
}
