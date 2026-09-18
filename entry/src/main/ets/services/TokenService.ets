/**
 * TokenService —— Token 用量数据访问
 *
 * S8 引入。服务端三个接口在 S8 之前就已实现，本层只做「取数 + 映射到模型」。
 * 所有请求走 S5 的统一客户端 HermesRest（鉴权 / 超时 / 重试都已收口）。
 *
 * ⚠️ 映射而不是直接 as 强转：ArkTS 对结构化类型比较严格，服务端字段是 snake_case、
 * 模型是 camelCase，这里逐字段搬运，避免 as 转换在运行时拿到 undefined。
 */

import { rest } from '../core/HermesRest.ets';
import {
  TokenSummary, TodayStats, MonthStats, AllTimeStats, ModelStats,
  DailySeries, DailyPoint, MonthlySeries, MonthlyPoint
} from '../models/ApiModels.ets';

export class TokenService {
  /** 今日 / 本月 / 总计 + 按模型分布 */
  public async fetchSummary(): Promise<TokenSummary> {
    const raw: Record<string, Object> = await rest.get('/api/tokens/summary') as Record<string, Object>;
    return TokenService.mapSummary(raw);
  }

  /** 近 days 天逐日用量 */
  public async fetchDaily(days: number): Promise<DailySeries> {
    const q: Record<string, string> = { 'days': String(days) };
    const raw: Record<string, Object> = await rest.get('/api/tokens/daily', q) as Record<string, Object>;
    return TokenService.mapDaily(raw);
  }

  /** 近 months 月逐月用量 */
  public async fetchMonthly(months: number): Promise<MonthlySeries> {
    const q: Record<string, string> = { 'months': String(months) };
    const raw: Record<string, Object> = await rest.get('/api/tokens/monthly', q) as Record<string, Object>;
    return TokenService.mapMonthly(raw);
  }

  // ── 映射 ──────────────────────────────────────────────────────────

  private static num(o: Record<string, Object>, key: string): number {
    const v: Object | undefined = o[key];
    return typeof v === 'number' ? v as number : 0;
  }

  private static str(o: Record<string, Object>, key: string): string {
    const v: Object | undefined = o[key];
    return typeof v === 'string' ? v as string : '';
  }

  private static mapSummary(raw: Record<string, Object>): TokenSummary {
    const out: TokenSummary = new TokenSummary();

    const t: Record<string, Object> = (raw['today'] as Record<string, Object>) ?? {};
    const today: TodayStats = new TodayStats();
    today.inputTokens = TokenService.num(t, 'input_tokens');
    today.outputTokens = TokenService.num(t, 'output_tokens');
    today.totalTokens = TokenService.num(t, 'total_tokens');
    out.today = today;

    const m: Record<string, Object> = (raw['this_month'] as Record<string, Object>) ?? {};
    const month: MonthStats = new MonthStats();
    month.inputTokens = TokenService.num(m, 'input_tokens');
    month.outputTokens = TokenService.num(m, 'output_tokens');
    month.totalTokens = TokenService.num(m, 'total_tokens');
    month.sessions = TokenService.num(m, 'sessions');
    month.activeDays = TokenService.num(m, 'active_days');
    month.dailyAverage = TokenService.num(m, 'daily_average');
    month.projectedTotal = TokenService.num(m, 'projected_total');
    out.thisMonth = month;

    const a: Record<string, Object> = (raw['all_time'] as Record<string, Object>) ?? {};
    const all: AllTimeStats = new AllTimeStats();
    all.inputTokens = TokenService.num(a, 'input_tokens');
    all.outputTokens = TokenService.num(a, 'output_tokens');
    all.totalTokens = TokenService.num(a, 'total_tokens');
    all.sessions = TokenService.num(a, 'sessions');
    out.allTime = all;

    const models: ModelStats[] = [];
    const arr: Object[] = (raw['by_model'] as Object[]) ?? [];
    for (const item of arr) {
      const r: Record<string, Object> = item as Record<string, Object>;
      const ms: ModelStats = new ModelStats();
      ms.model = TokenService.str(r, 'model');
      ms.inputTokens = TokenService.num(r, 'input_tokens');
      ms.outputTokens = TokenService.num(r, 'output_tokens');
      ms.totalTokens = TokenService.num(r, 'total_tokens');
      ms.sessions = TokenService.num(r, 'sessions');
      models.push(ms);
    }
    out.byModel = models;
    return out;
  }

  private static mapDaily(raw: Record<string, Object>): DailySeries {
    const out: DailySeries = new DailySeries();
    out.period = TokenService.str(raw, 'period');
    out.totalInputTokens = TokenService.num(raw, 'total_input_tokens');
    out.totalOutputTokens = TokenService.num(raw, 'total_output_tokens');
    out.totalTokens = TokenService.num(raw, 'total_tokens');

    const list: DailyPoint[] = [];
    const arr: Object[] = (raw['daily'] as Object[]) ?? [];
    for (const item of arr) {
      const r: Record<string, Object> = item as Record<string, Object>;
      const p: DailyPoint = new DailyPoint();
      p.date = TokenService.str(r, 'date');
      p.inputTokens = TokenService.num(r, 'input_tokens');
      p.outputTokens = TokenService.num(r, 'output_tokens');
      p.totalTokens = TokenService.num(r, 'total_tokens');
      p.sessions = TokenService.num(r, 'sessions');
      list.push(p);
    }
    out.daily = list;
    return out;
  }

  private static mapMonthly(raw: Record<string, Object>): MonthlySeries {
    const out: MonthlySeries = new MonthlySeries();
    out.period = TokenService.str(raw, 'period');

    const list: MonthlyPoint[] = [];
    const arr: Object[] = (raw['monthly'] as Object[]) ?? [];
    for (const item of arr) {
      const r: Record<string, Object> = item as Record<string, Object>;
      const p: MonthlyPoint = new MonthlyPoint();
      p.month = TokenService.str(r, 'month');
      p.inputTokens = TokenService.num(r, 'input_tokens');
      p.outputTokens = TokenService.num(r, 'output_tokens');
      p.totalTokens = TokenService.num(r, 'total_tokens');
      p.sessions = TokenService.num(r, 'sessions');
      p.activeDays = TokenService.num(r, 'active_days');
      list.push(p);
    }
    out.monthly = list;
    return out;
  }
}

export const tokenService: TokenService = new TokenService();

/**
 * 把 token 数格式化成易读形式。
 * 9.75 亿这种量级直接显示原始数字没人看得懂。
 */
export function formatTokens(n: number): string {
  if (n >= 100000000) {
    return (n / 100000000).toFixed(2) + ' 亿';
  }
  if (n >= 10000) {
    return (n / 10000).toFixed(1) + ' 万';
  }
  return String(n);
}

/** 千分位（用于需要精确值的场景） */
export function withCommas(n: number): string {
  const s: string = String(n);
  let out: string = '';
  let c: number = 0;
  for (let i: number = s.length - 1; i >= 0; i--) {
    out = s.charAt(i) + out;
    c++;
    if (c % 3 === 0 && i > 0) {
      out = ',' + out;
    }
  }
  return out;
}

/** 把 '2026-09-18' 显示成 '09-18' */
export function shortDate(d: string): string {
  return d.length >= 10 ? d.substring(5) : d;
}
