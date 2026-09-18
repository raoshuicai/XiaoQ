/**
 * WebSocket 消息类型定义（纯类型，零逻辑）
 *
 * S1 抽取：从 utils/WebSocketClient.ets 搬来，字段与原定义一字不差。
 * ⚠️ 所有 `?` 可选项必须保持可选，不得改成必填 —— 服务端按需下发字段。
 *
 * 事件名常量（Events）**不在本文件**：按方案 V2 §2.1，它归 core/EventBus.ets
 * （S2 创建）。这是 MoA 评审 MoA-1 #10 指出的归属矛盾，不要在这里重复定义。
 *
 * 本文件不得 import 任何业务代码（见方案 V2 §2.2 分层铁律）。
 */

export interface WsMessage {
  type: string;
  // 推送/授权
  id?: string;
  title?: string;
  description?: string;
  details?: Object[];
  requester?: string;
  body?: string;
  approved?: boolean;
  timestamp?: number;
  // 流式聊天
  content?: string;       // chat_token 内容
  name?: string;          // 工具名
  arguments?: string;     // 工具参数
  message?: string;       // chat_error 信息
  // 聊天请求
  messages?: Object[];    // 消息历史
  session_id?: string;    // 会话ID（当前语义 = 固定的 device_id，见方案 V2 §3 决策 1）
  // 授权卡片（新格式）
  run_id?: string;        // Hermes 运行ID
  command?: string;       // 需要授权的命令
  pattern_keys?: string[];// 匹配的模式
  choices?: string[];     // 可选操作列表
  // 断点续流（方案三）
  seq?: number;           // token 序列号
  last_seq?: number;      // 客户端最后收到的 seq
  caught_up?: number;     // sync_resume 追回的 token 数
}

export type WsCallback = (msg: WsMessage) => void;
