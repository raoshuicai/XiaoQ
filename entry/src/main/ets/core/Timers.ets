/**
 * Timers —— 计时器抽象
 *
 * S3 引入。为什么需要它（MoA-1 #4 指出的关键问题）：
 *   ChatStreamEngine 依赖三个计时器（20s 停滞 / 5s 重试 / 30s 兜底）。
 *   如果直接用全局 setTimeout，引擎就**无法在单元测试里换掉时间** ——
 *   所谓"可测试"只是口号。注入 Clock 之后，测试可以传 FakeClock 手推
 *   虚拟时间，从而真正验证"重试跑满 12 次""30 秒兜底触发"这类行为。
 *
 * ⚠️ ArkTS 限制（实测踩坑）：**不能用对象字面量实现 interface**
 *    （arkts-no-untyped-obj-literals，编译报 10605038）。
 *    所以 Clock 声明为 abstract class，由 SystemClock 继承实现 ——
 *    不要改回 interface + 字面量写法。
 *
 * 分层约束：本文件属于 core/，不得 import 任何 ArkUI 或业务模块。
 */

export abstract class Clock {
  abstract setTimeout(fn: () => void, ms: number): number;
  abstract clearTimeout(id: number): void;
  abstract setInterval(fn: () => void, ms: number): number;
  abstract clearInterval(id: number): void;
}

/** 无效计时器 id。引擎内部用它代替 undefined 做判空（Clock 返回 number） */
export const NO_TIMER: number = -1;

/** 生产环境实现：转派到宿主环境真计时器 */
export class SystemClock extends Clock {
  setTimeout(fn: () => void, ms: number): number {
    const id: number = setTimeout(fn, ms);
    return id;
  }

  clearTimeout(id: number): void {
    clearTimeout(id);
  }

  setInterval(fn: () => void, ms: number): number {
    const id: number = setInterval(fn, ms);
    return id;
  }

  clearInterval(id: number): void {
    clearInterval(id);
  }
}

export const systemClock: Clock = new SystemClock();
