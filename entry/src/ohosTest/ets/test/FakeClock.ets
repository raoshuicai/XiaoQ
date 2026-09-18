/**
 * FakeClock —— 手推虚拟时间的 Clock 实现（测试专用）
 *
 * S3 建立。共享给 ChatStreamEngine / ChatService 等所有需要控制时间的测试。
 * 让"20s 停滞""5s×12 重试""500ms 防抖持久化"这类时间逻辑能在毫秒内验证。
 *
 * ⚠️ ArkTS 不允许对象字面量（arkts-no-untyped-obj-literals），
 *    所以计时任务用 class 而非对象字面量表示。
 */

import { Clock } from '../../../main/ets/core/Timers.ets';

class FakeTimeout {
  at: number = 0;
  fn: () => void = (): void => {};

  constructor(at: number, fn: () => void) {
    this.at = at;
    this.fn = fn;
  }
}

class FakeInterval {
  nextAt: number = 0;
  period: number = 0;
  fn: () => void = (): void => {};

  constructor(nextAt: number, period: number, fn: () => void) {
    this.nextAt = nextAt;
    this.period = period;
    this.fn = fn;
  }
}

export class FakeClock extends Clock {
  private now: number = 0;
  private seq: number = 0;
  private timeouts: Map<number, FakeTimeout> = new Map<number, FakeTimeout>();
  private intervals: Map<number, FakeInterval> = new Map<number, FakeInterval>();

  setTimeout(fn: () => void, ms: number): number {
    this.seq = this.seq + 1;
    this.timeouts.set(this.seq, new FakeTimeout(this.now + ms, fn));
    return this.seq;
  }

  clearTimeout(id: number): void {
    this.timeouts.delete(id);
  }

  setInterval(fn: () => void, ms: number): number {
    this.seq = this.seq + 1;
    this.intervals.set(this.seq, new FakeInterval(this.now + ms, ms, fn));
    return this.seq;
  }

  clearInterval(id: number): void {
    this.intervals.delete(id);
  }

  /** 推进虚拟时间，按到期先后逐个触发任务 */
  advance(ms: number): void {
    const target: number = this.now + ms;
    let guard: number = 0;
    while (guard < 100000) {
      guard = guard + 1;

      let earliest: number = Number.MAX_SAFE_INTEGER;
      this.timeouts.forEach((job: FakeTimeout): void => {
        if (job.at <= target && job.at < earliest) {
          earliest = job.at;
        }
      });
      this.intervals.forEach((job: FakeInterval): void => {
        if (job.nextAt <= target && job.nextAt < earliest) {
          earliest = job.nextAt;
        }
      });
      if (earliest === Number.MAX_SAFE_INTEGER) {
        break;
      }
      this.now = earliest;

      const dueTimeouts: number[] = [];
      this.timeouts.forEach((job: FakeTimeout, id: number): void => {
        if (job.at <= this.now) {
          dueTimeouts.push(id);
        }
      });
      for (let i: number = 0; i < dueTimeouts.length; i++) {
        const job: FakeTimeout | undefined = this.timeouts.get(dueTimeouts[i]);
        this.timeouts.delete(dueTimeouts[i]);
        if (job !== undefined) {
          job.fn();
        }
      }

      const dueIntervals: number[] = [];
      this.intervals.forEach((job: FakeInterval, id: number): void => {
        if (job.nextAt <= this.now) {
          dueIntervals.push(id);
        }
      });
      for (let i: number = 0; i < dueIntervals.length; i++) {
        const job: FakeInterval | undefined = this.intervals.get(dueIntervals[i]);
        if (job !== undefined) {
          job.nextAt = this.now + job.period;
          job.fn();
        }
      }
    }
    this.now = target;
  }

  getNow(): number {
    return this.now;
  }

  /** 未清除的计时器数量 —— 用于验证 reset/dispose/防抖是否清干净 */
  pendingCount(): number {
    return this.timeouts.size + this.intervals.size;
  }
}
