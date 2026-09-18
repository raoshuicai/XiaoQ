/**
 * DiscoveryService —— 模型 / 技能 / 记忆 数据访问（S13）
 *
 * 模型切换是**写操作**（改 Hermes 的 config.yaml），走 postOnce 不重试。
 * 生效时机 = 下一次对话（服务端不改正在进行的流）。
 */

import { rest } from '../core/HermesRest.ets';
import { ModelItem, SwitchResult, SkillItem, MemoryInfo } from '../models/DiscoveryModels.ets';

export class DiscoveryService {
  /** 可用模型（含 current 标记）*/
  public async fetchModels(): Promise<ModelItem[]> {
    const raw: Record<string, Object> = await rest.get('/api/models') as Record<string, Object>;
    const out: ModelItem[] = [];
    const arr: Object[] = (raw['items'] as Object[]) ?? [];
    for (const it of arr) {
      const r: Record<string, Object> = it as Record<string, Object>;
      const m: ModelItem = new ModelItem();
      m.id = DiscoveryService.str(r, 'id');
      m.name = DiscoveryService.str(r, 'name');
      m.provider = DiscoveryService.str(r, 'provider');
      m.current = r['current'] === true;
      out.push(m);
    }
    return out;
  }

  /**
   * 切换默认模型。
   * ⚠️ 副作用接口 -> postOnce（重试可能造成来回改写配置）。
   * 服务端: 不在已知集合里 -> 404 MODEL_NOT_FOUND。
   */
  public async switchModel(id: string): Promise<SwitchResult> {
    const body: Record<string, Object> = { 'id': id };
    const raw: Record<string, Object> = await rest.postOnce('/api/models/switch', body) as Record<string, Object>;
    const r: SwitchResult = new SwitchResult();
    r.id = DiscoveryService.str(raw, 'id');
    r.appliedAt = DiscoveryService.str(raw, 'applied_at');
    r.previous = DiscoveryService.str(raw, 'previous');
    r.note = DiscoveryService.str(raw, 'note');
    return r;
  }

  /** 技能列表（q 为空则全量）*/
  public async fetchSkills(q: string): Promise<SkillItem[]> {
    const query: Record<string, string> = {};
    if (q.length > 0) {
      query['q'] = q;
    }
    const raw: Record<string, Object> = await rest.get('/api/skills', query) as Record<string, Object>;
    const out: SkillItem[] = [];
    const arr: Object[] = (raw['items'] as Object[]) ?? [];
    for (const it of arr) {
      const r: Record<string, Object> = it as Record<string, Object>;
      const s: SkillItem = new SkillItem();
      s.name = DiscoveryService.str(r, 'name');
      s.description = DiscoveryService.str(r, 'description');
      s.category = DiscoveryService.str(r, 'category');
      out.push(s);
    }
    return out;
  }

  /** Agent 记忆文件 */
  public async fetchMemory(): Promise<MemoryInfo> {
    const raw: Record<string, Object> = await rest.get('/api/memory') as Record<string, Object>;
    const m: MemoryInfo = new MemoryInfo();
    m.content = DiscoveryService.str(raw, 'content');
    m.exists = raw['exists'] === true;
    m.size = DiscoveryService.num(raw, 'size');
    m.updatedAt = DiscoveryService.num(raw, 'updated_at');
    return m;
  }

  private static str(o: Record<string, Object>, key: string): string {
    const v: Object | undefined = o[key];
    return typeof v === 'string' ? v as string : '';
  }

  private static num(o: Record<string, Object>, key: string): number {
    const v: Object | undefined = o[key];
    return typeof v === 'number' ? v as number : 0;
  }
}

export const discoveryService: DiscoveryService = new DiscoveryService();
