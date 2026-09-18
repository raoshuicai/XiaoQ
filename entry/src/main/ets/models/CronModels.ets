/**
 * CronModels —— 定时任务数据模型
 *
 * S10 引入。对照 xiaoq-api 的真实响应（字段由服务端 _cron_job_view 裁剪）：
 *   GET  /api/cron/jobs               -> {items:[{id,name,schedule,enabled,state,
 *                                          next_run_at,last_run_at,last_status,
 *                                          last_error,deliver,no_agent,script}],
 *                                         total, has_more}
 *   POST /api/cron/jobs/{id}/toggle   -> {id, enabled, changed, next_run_at}
 *   POST /api/cron/jobs/{id}/run      -> {status:"triggered", run_id}
 *
 * 服务端只下发 APP 需要的字段 —— 不含 prompt / 凭据。
 */

/** 一个定时任务 */
export class CronJob {
  id: string = '';
  name: string = '';
  /** 人类可读的调度表达式，如 `0 9 * * *` 或 `every 2h` */
  schedule: string = '';
  enabled: boolean = false;
  /** scheduled | paused */
  state: string = '';
  nextRunAt: string = '';
  lastRunAt: string = '';
  /** ok | error | (空) */
  lastStatus: string = '';
  lastError: string = '';
  /** local | feishu | ... */
  deliver: string = '';
  /** true = 直接跑脚本，不经过 agent */
  noAgent: boolean = false;
  script: string = '';
}

/** toggle 的结果 */
export class ToggleResult {
  id: string = '';
  enabled: boolean = false;
  /** false = 本来就是目标状态（幂等命中），没有实际写盘 */
  changed: boolean = false;
  nextRunAt: string = '';
}

/** run 的结果 */
export class RunResult {
  status: string = '';
  runId: string = '';
}
