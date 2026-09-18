/**
 * DiscoveryModels —— 模型 / 技能 / 记忆 数据模型
 *
 * S13 引入。对照 xiaoq-api 的真实响应：
 *   GET  /api/models   -> {items:[{id,name,provider,current}], total}
 *   POST /api/models/switch {id} -> {id, applied_at, previous, note}
 *   GET  /api/skills?q -> {items:[{name,description,category}], total}
 *   GET  /api/memory   -> {content, exists, size, updated_at}
 */

/** 一个可用模型 */
export class ModelItem {
  id: string = '';
  name: string = '';
  provider: string = '';
  /** 是否当前默认模型 */
  current: boolean = false;
}

/** 切换模型的结果 */
export class SwitchResult {
  id: string = '';
  appliedAt: string = '';
  previous: string = '';
  note: string = '';
}

/** 一个技能 */
export class SkillItem {
  name: string = '';
  description: string = '';
  category: string = '';
}

/** 记忆文件 */
export class MemoryInfo {
  content: string = '';
  exists: boolean = false;
  size: number = 0;
  updatedAt: number = 0;
}
