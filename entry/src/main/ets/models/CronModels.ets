/**
 * CronModels —— 定时任务数据模型
 *
 * S10 引入。对照 xiaoq-api 的真实响应（字段由服务端裁剪）：
 *   GET  /api/cron/jobs                -> {items:[{...}], total, has_more}
 *   GET  /api/cron/jobs/{id}           -> 详情（多出 prompt / schedule_expr / 运行历史数等）
 *   GET  /api/cron/jobs/{id}/outputs   -> {items:[{name,size,mtime}], total}
 *   GET  /api/cron/jobs/{id}/outputs/{name} -> {name, content, truncated}
 *   POST /api/cron/jobs/{id}/toggle    -> {id, enabled, changed, next_run_at}
 *   POST /api/cron/jobs/{id}/run       -> {status:"triggered", run_id}
 *   POST /api/cron/jobs/{id}/update    -> 更新后的详情
 *
 * 服务端列表接口不下发 prompt（避免列表响应过大 / 暴露不必要内容），
 * 详情接口才给。
 */

/** 一个定时任务（列表项） */
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

/** 详情（列表字段 + 只有详情页需要的） */
export class CronJobDetail extends CronJob {
  /** agent 类型的任务才有内容；脚本类型的为空 */
  prompt: string = '';
  /** cron | interval | once */
  scheduleKind: string = '';
  /** 原始表达式（可视化编辑用） */
  scheduleExpr: string = '';
  /** null 表示无限重复 -> 用 -1 承载 */
  repeatTimes: number = -1;
  repeatCompleted: number = 0;
  createdAt: string = '';
  pausedAt: string = '';
  pausedReason: string = '';
  model: string = '';
  provider: string = '';
  workdir: string = '';
  skills: string[] = [];
  /** output 目录里的历史次数 */
  runHistoryCount: number = 0;
}

/** 一次运行的输出文件 */
export class CronOutput {
  name: string = '';
  size: number = 0;
  mtime: number = 0;
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
