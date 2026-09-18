/**
 * CronService —— 定时任务数据访问
 *
 * S10 引入。服务端三个接口（S10a）已就绪，本层只做取数 + 映射。
 * 所有请求走 S5 的统一客户端 HermesRest。
 */

import { rest } from '../core/HermesRest.ets';
import { CronJob, CronJobDetail, CronOutput, ToggleResult, RunResult } from '../models/CronModels.ets';

export class CronService {
  /** 列出全部任务（含已暂停），按下次执行时间排序 */
  public async fetchJobs(): Promise<CronJob[]> {
    const raw: Record<string, Object> = await rest.get('/api/cron/jobs') as Record<string, Object>;
    const out: CronJob[] = [];
    const arr: Object[] = (raw['items'] as Object[]) ?? [];
    for (const item of arr) {
      out.push(CronService.mapJob(item as Record<string, Object>));
    }
    return out;
  }

  /**
   * 启用 / 暂停。
   * 服务端幂等：重复设同值返回 changed=false，不算错误。
   */
  public async toggle(id: string, enabled: boolean): Promise<ToggleResult> {
    const body: Record<string, Object> = { 'enabled': enabled };
    const raw: Record<string, Object> = await rest.post(
      '/api/cron/jobs/' + encodeURIComponent(id) + '/toggle', body
    ) as Record<string, Object>;

    const r: ToggleResult = new ToggleResult();
    r.id = CronService.str(raw, 'id');
    r.enabled = raw['enabled'] === true;
    r.changed = raw['changed'] === true;
    r.nextRunAt = CronService.str(raw, 'next_run_at');
    return r;
  }

  /**
   * 立即执行一次。
   *
   * ⚠️ 走 postOnce 而不是 post：这是**副作用接口**，重试会导致重复触发。
   * ⚠️ 抛出的错误里带服务端的 detail，调用方据此区分：
   *    JOB_PAUSED          任务已暂停，需要先启用
   *    JOB_ALREADY_RUNNING 已有一次执行在跑
   */
  public async run(id: string): Promise<RunResult> {
    // ArkTS：对象字面量必须对应显式类型，空 body 也得先声明
    const empty: Record<string, string> = {};
    const raw: Record<string, Object> = await rest.postOnce(
      '/api/cron/jobs/' + encodeURIComponent(id) + '/run', empty
    ) as Record<string, Object>;

    const r: RunResult = new RunResult();
    r.status = CronService.str(raw, 'status');
    r.runId = CronService.str(raw, 'run_id');
    return r;
  }

  /** 单个任务详情（含 prompt 全文与运行历史数） */
  public async fetchDetail(id: string): Promise<CronJobDetail> {
    const raw: Record<string, Object> = await rest.get(
      '/api/cron/jobs/' + encodeURIComponent(id)
    ) as Record<string, Object>;
    return CronService.mapDetail(raw);
  }

  /** 该任务的运行输出列表（新→旧） */
  public async fetchOutputs(id: string): Promise<CronOutput[]> {
    const raw: Record<string, Object> = await rest.get(
      '/api/cron/jobs/' + encodeURIComponent(id) + '/outputs'
    ) as Record<string, Object>;
    const out: CronOutput[] = [];
    const arr: Object[] = (raw['items'] as Object[]) ?? [];
    for (const item of arr) {
      const r: Record<string, Object> = item as Record<string, Object>;
      const o: CronOutput = new CronOutput();
      o.name = CronService.str(r, 'name');
      o.size = CronService.num(r, 'size');
      o.mtime = CronService.num(r, 'mtime');
      out.push(o);
    }
    return out;
  }

  /** 读一次运行的输出内容（服务端最多返回 200KB） */
  public async fetchOutputContent(id: string, name: string): Promise<string> {
    const raw: Record<string, Object> = await rest.get(
      '/api/cron/jobs/' + encodeURIComponent(id) + '/outputs/' + encodeURIComponent(name)
    ) as Record<string, Object>;
    return CronService.str(raw, 'content');
  }

  /**
   * 编辑任务（只放开 name / schedule）。
   *
   * ⚠️ 走 postOnce：这是写操作，重试可能造成重复更新。
   * ⚠️ 服务端只接受 name / schedule 两个字段，其余字段（prompt、script、
   *    no_agent 等）改动面大，继续在 Hermes 侧用 CLI 改更稳妥。
   * ⚠️ 非法 schedule 表达式服务端会返 400 INVALID_SCHEDULE（含支持的格式说明）。
   */
  public async update(id: string, name: string, schedule: string): Promise<CronJobDetail> {
    const body: Record<string, Object> = {};
    if (name.length > 0) {
      body['name'] = name;
    }
    if (schedule.length > 0) {
      body['schedule'] = schedule;
    }
    const raw: Record<string, Object> = await rest.postOnce(
      '/api/cron/jobs/' + encodeURIComponent(id) + '/update', body
    ) as Record<string, Object>;
    return CronService.mapDetail(raw);
  }

  private static mapDetail(r: Record<string, Object>): CronJobDetail {
    const j: CronJobDetail = new CronJobDetail();
    const base: CronJob = CronService.mapJob(r);
    j.id = base.id;
    j.name = base.name;
    j.schedule = base.schedule;
    j.enabled = base.enabled;
    j.state = base.state;
    j.nextRunAt = base.nextRunAt;
    j.lastRunAt = base.lastRunAt;
    j.lastStatus = base.lastStatus;
    j.lastError = base.lastError;
    j.deliver = base.deliver;
    j.noAgent = base.noAgent;
    j.script = base.script;

    j.prompt = CronService.str(r, 'prompt');
    j.scheduleKind = CronService.str(r, 'schedule_kind');
    j.scheduleExpr = CronService.str(r, 'schedule_expr');
    const rt: Object | undefined = r['repeat_times'];
    j.repeatTimes = typeof rt === 'number' ? rt as number : -1;
    j.repeatCompleted = CronService.num(r, 'repeat_completed');
    j.createdAt = CronService.str(r, 'created_at');
    j.pausedAt = CronService.str(r, 'paused_at');
    j.pausedReason = CronService.str(r, 'paused_reason');
    j.model = CronService.str(r, 'model');
    j.provider = CronService.str(r, 'provider');
    j.workdir = CronService.str(r, 'workdir');
    j.runHistoryCount = CronService.num(r, 'run_history_count');

    const skills: string[] = [];
    const arr: Object[] = (r['skills'] as Object[]) ?? [];
    for (const s of arr) {
      if (typeof s === 'string') {
        skills.push(s as string);
      }
    }
    j.skills = skills;
    return j;
  }

  private static mapJob(r: Record<string, Object>): CronJob {
    const j: CronJob = new CronJob();
    j.id = CronService.str(r, 'id');
    j.name = CronService.str(r, 'name');
    j.schedule = CronService.str(r, 'schedule');
    j.enabled = r['enabled'] === true;
    j.state = CronService.str(r, 'state');
    j.nextRunAt = CronService.str(r, 'next_run_at');
    j.lastRunAt = CronService.str(r, 'last_run_at');
    j.lastStatus = CronService.str(r, 'last_status');
    j.lastError = CronService.str(r, 'last_error');
    j.deliver = CronService.str(r, 'deliver');
    j.noAgent = r['no_agent'] === true;
    j.script = CronService.str(r, 'script');
    return j;
  }

  private static str(o: Record<string, Object>, key: string): string {
    const v: Object | undefined = o[key];
    if (typeof v === 'string') {
      return v as string;
    }
    return '';
  }

  private static num(o: Record<string, Object>, key: string): number {
    const v: Object | undefined = o[key];
    return typeof v === 'number' ? v as number : 0;
  }
}

export const cronService: CronService = new CronService();

/** '2026-09-19T09:00:00+08:00' -> '09-19 09:00'（本地展示用） */
export function shortDateTime(s: string): string {
  if (s.length >= 16 && s.charAt(4) === '-') {
    return s.substring(5, 10) + ' ' + s.substring(11, 16);
  }
  return s.length > 0 ? s : '—';
}

/** 判断任务是否处于"有错误"状态 */
export function hasError(j: CronJob): boolean {
  return j.lastStatus === 'error' || j.lastError.length > 0;
}
