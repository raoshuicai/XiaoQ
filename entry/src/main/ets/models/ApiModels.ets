/**
 * ApiModels —— Token 用量接口的数据模型
 *
 * S8 引入。字段严格对照 xiaoq-api 的真实响应（先 curl 拿到样本再写模型，
 * 不凭文档猜）。字段名不一致时以服务端为准，客户端用 record 取值后逐字段映射。
 *
 * 服务端接口：
 *   GET /api/tokens/summary         今日 / 本月 / 总计 / 按模型分布
 *   GET /api/tokens/daily?days=N    近 N 天逐日用量
 *   GET /api/tokens/monthly?months=N 近 N 月逐月用量
 */

/** 一组 token 计数（三个接口共有的基础形态） */
export class TokenTrio {
  inputTokens: number = 0;
  outputTokens: number = 0;
  totalTokens: number = 0;
}

/** 今日用量 */
export class TodayStats extends TokenTrio {
}

/** 本月用量（比 TokenTrio 多出会话数/活跃天数/日均/预测） */
export class MonthStats extends TokenTrio {
  sessions: number = 0;
  activeDays: number = 0;
  dailyAverage: number = 0;
  projectedTotal: number = 0;
}

/** 累计用量 */
export class AllTimeStats extends TokenTrio {
  sessions: number = 0;
}

/** 单个模型的用量 */
export class ModelStats extends TokenTrio {
  model: string = '';
  sessions: number = 0;
}

/** /api/tokens/summary 的完整响应 */
export class TokenSummary {
  today: TodayStats = new TodayStats();
  thisMonth: MonthStats = new MonthStats();
  allTime: AllTimeStats = new AllTimeStats();
  byModel: ModelStats[] = [];
}

/** 某一天的用量 */
export class DailyPoint extends TokenTrio {
  date: string = '';
  sessions: number = 0;
}

/** /api/tokens/daily 的完整响应 */
export class DailySeries {
  period: string = '';
  totalInputTokens: number = 0;
  totalOutputTokens: number = 0;
  totalTokens: number = 0;
  daily: DailyPoint[] = [];
}

/** 某个月的用量 */
export class MonthlyPoint extends TokenTrio {
  month: string = '';
  sessions: number = 0;
  activeDays: number = 0;
}

/** /api/tokens/monthly 的完整响应 */
export class MonthlySeries {
  period: string = '';
  monthly: MonthlyPoint[] = [];
}
