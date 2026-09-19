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

/**
 * S41：一轮对话的性能指标。
 * 由服务端在 `chat_done` 帧的 `metrics` 字段带回（读 perf_metrics.jsonl 聚合 + 自计 TTFT）。
 * 老服务端不带该字段 → 为 undefined → 气泡里不渲染指标行。
 */
export interface MsgMetrics {
  /** 首 token 延迟（ms）。服务端从"请求发出 → 首个 token"自计 */
  ttft_ms?: number;
  /** 解码速度（tok/s）。jsonl 的 output_tokens ÷ 本轮墙钟时长 */
  tps?: number;
  /** KV 缓存命中率（0~1）。jsonl 的 cache_read_tokens ÷ prompt_tokens */
  kv_hit?: number;
  /** 本轮 API 调用次数（工具轮会 > 1） */
  calls?: number;
  tokens_in?: number;
  tokens_out?: number;
  /** 本轮墙钟跨度（秒） */
  span_s?: number;
}

/** 聊天消息 —— UI 列表项 */
export interface ChatMessage {
  role: string;
  content: string;
  /** S4：消息唯一标识。旧数据没有此字段，迁移时按"索引+时间戳"补写 */
  msg_id?: string;
  /** S21：消息时间（毫秒时间戳）。用于气泡上方的"当天=时:分 / 非当天=月-日 时:分" */
  createdAt?: number;
  /** S41：本轮的 TTFT / TPS / KV 命中。仅 assistant 的最新一条会有 */
  metrics?: MsgMetrics;
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
