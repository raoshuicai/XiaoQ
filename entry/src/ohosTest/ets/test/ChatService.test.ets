/**
 * ChatService 单元测试
 *
 * 覆盖不依赖 Preferences/Context 的纯逻辑部分：
 *   - buildHistoryForLlm() 的占位符过滤（**最关键** —— 历史上这里是各处各写一遍，
 *     漏写就会把「⏳ 正在恢复连接...」喂给模型）
 *   - append / deleteAt / replaceIndicator / setMessages 的语义
 *   - 防抖持久化的计时器管理（用 FakeClock 验证，无需真等 500ms）
 *
 * 迁移逻辑（loadSaved）依赖 Preferences + Context，无法在单测里构造，
 * 由 S4 的人工验证步骤覆盖（先装 v2.0.7 造数据 → 再装新版 → 看是否迁移）。
 */

import { describe, it, expect, beforeEach } from '@ohos/hypium';
import { ChatService } from '../../../main/ets/services/ChatService.ets';
import { ChatMessage, ChatRecord } from '../../../main/ets/models/ChatModels.ets';
import { FakeClock } from './FakeClock.ets';

const SAVE_DEBOUNCE: number = 500;
const PLACEHOLDER: string = '⏳ 正在恢复连接...当前网络：🌐 公网';

export default function chatServiceTest() {
  describe('ChatServiceTest', () => {
    let clock: FakeClock;
    let svc: ChatService;

    beforeEach(() => {
      clock = new FakeClock();
      svc = new ChatService(clock);
    });

    // ─────────────────── 消息变更 ───────────────────

    it('append_adds_message_with_msg_id', 0, () => {
      svc.append('user', '你好');
      const list: ChatMessage[] = svc.getMessages();
      expect(list.length).assertEqual(1);
      expect(list[0].role).assertEqual('user');
      expect(list[0].content).assertEqual('你好');
      expect(list[0].msg_id !== undefined && list[0].msg_id !== '').assertTrue();
    });

    it('append_preserves_order', 0, () => {
      svc.append('user', 'A');
      svc.append('assistant', 'B');
      svc.append('user', 'C');
      const list: ChatMessage[] = svc.getMessages();
      expect(list.length).assertEqual(3);
      expect(list[0].content).assertEqual('A');
      expect(list[1].content).assertEqual('B');
      expect(list[2].content).assertEqual('C');
    });

    it('delete_at_removes_correct_item', 0, () => {
      svc.append('user', 'A');
      svc.append('assistant', 'B');
      svc.append('user', 'C');
      const ok: boolean = svc.deleteAt(1);
      expect(ok).assertTrue();
      const list: ChatMessage[] = svc.getMessages();
      expect(list.length).assertEqual(2);
      expect(list[0].content).assertEqual('A');
      expect(list[1].content).assertEqual('C');
    });

    it('delete_at_out_of_range_returns_false', 0, () => {
      svc.append('user', 'A');
      expect(svc.deleteAt(-1)).assertFalse();
      expect(svc.deleteAt(5)).assertFalse();
      expect(svc.getMessages().length).assertEqual(1);
    });

    it('set_messages_replaces_whole_list', 0, () => {
      svc.append('user', 'old');
      const fresh: ChatMessage[] = [{ role: 'assistant', content: 'new' }];
      svc.setMessages(fresh);
      const list: ChatMessage[] = svc.getMessages();
      expect(list.length).assertEqual(1);
      expect(list[0].content).assertEqual('new');
    });

    // ─────────────────── 占位符替换 ───────────────────

    it('replace_indicator_finds_last_placeholder', 0, () => {
      svc.append('user', '问题');
      svc.append('assistant', PLACEHOLDER);
      const ok: boolean = svc.replaceIndicator('真正的回复');
      expect(ok).assertTrue();
      const list: ChatMessage[] = svc.getMessages();
      expect(list.length).assertEqual(2);
      expect(list[1].content).assertEqual('真正的回复');
    });

    it('replace_indicator_returns_false_when_absent', 0, () => {
      svc.append('user', '问题');
      svc.append('assistant', '正常回复');
      const ok: boolean = svc.replaceIndicator('不该被写入');
      expect(ok).assertFalse();
      expect(svc.getMessages().length).assertEqual(2);
      expect(svc.getMessages()[1].content).assertEqual('正常回复');
    });

    it('replace_indicator_replaces_only_last_one', 0, () => {
      // 历史教训：重复断线会插多条占位符，替换只应命中最后一条
      svc.append('assistant', PLACEHOLDER);
      svc.append('assistant', PLACEHOLDER);
      svc.replaceIndicator('X');
      const list: ChatMessage[] = svc.getMessages();
      expect(list.length).assertEqual(2);
      expect(list[0].content).assertEqual(PLACEHOLDER);
      expect(list[1].content).assertEqual('X');
    });

    // ─────────────────── LLM 上下文构建（核心）───────────────────

    it('build_history_filters_placeholder', 0, () => {
      svc.append('user', '问题一');
      svc.append('assistant', PLACEHOLDER);
      svc.append('assistant', '正常答复');
      const history: ChatRecord[] = svc.buildHistoryForLlm();
      // 占位符必须被剔除，其余原样保留
      expect(history.length).assertEqual(2);
      expect(history[0].content).assertEqual('问题一');
      expect(history[1].content).assertEqual('正常答复');
    });

    it('build_history_empty_when_no_messages', 0, () => {
      const history: ChatRecord[] = svc.buildHistoryForLlm();
      expect(history.length).assertEqual(0);
    });

    it('build_history_keeps_all_when_no_placeholder', 0, () => {
      svc.append('user', 'A');
      svc.append('assistant', 'B');
      const history: ChatRecord[] = svc.buildHistoryForLlm();
      expect(history.length).assertEqual(2);
      expect(history[0].role).assertEqual('user');
      expect(history[1].role).assertEqual('assistant');
    });

    it('build_history_filters_multiple_placeholders', 0, () => {
      svc.append('assistant', PLACEHOLDER);
      svc.append('user', '继续');
      svc.append('assistant', PLACEHOLDER);
      svc.append('assistant', '答复');
      const history: ChatRecord[] = svc.buildHistoryForLlm();
      expect(history.length).assertEqual(2);
      expect(history[0].content).assertEqual('继续');
      expect(history[1].content).assertEqual('答复');
    });

    // ─────────────────── 防抖持久化（计时器）───────────────────

    it('append_schedules_debounced_save', 0, () => {
      svc.append('user', 'A');
      // 防抖计时器已排上
      expect(clock.pendingCount() > 0).assertTrue();
    });

    it('rapid_appends_share_single_debounce_timer', 0, () => {
      svc.append('user', 'A');
      svc.append('user', 'B');
      svc.append('user', 'C');
      // 连续变更只应保留一个待触发的防抖计时器（每次重建前先 clear）
      expect(clock.pendingCount()).assertEqual(1);
    });

    it('debounce_timer_fires_after_500ms', 0, () => {
      svc.append('user', 'A');
      clock.advance(SAVE_DEBOUNCE - 1);
      expect(clock.pendingCount()).assertEqual(1);
      clock.advance(1);
      // 触发后计时器自我清除（ctx 为空时 flushNow 直接返回，不应崩）
      expect(clock.pendingCount()).assertEqual(0);
    });

    it('flush_without_context_does_not_crash', 0, () => {
      // ctx 未 bind 时 flushNow 应安全返回（单测环境没有 Context）
      svc.append('user', 'A');
      svc.flushNow();
      expect(svc.getMessages().length).assertEqual(1);
    });

    it('dispose_cancels_pending_debounce', 0, () => {
      svc.append('user', 'A');
      expect(clock.pendingCount() > 0).assertTrue();
      svc.dispose();
      expect(clock.pendingCount()).assertEqual(0);
    });
  });
}
