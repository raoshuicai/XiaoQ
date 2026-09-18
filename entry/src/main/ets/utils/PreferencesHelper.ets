/**
 * PreferencesHelper —— 本地持久化辅助
 *
 * S4 改动（方案 V2 §7.1 数据迁移方案）：
 *   消息存储从「单一全局 key `chat_messages`」改为「按会话分 key `msg_cache_{sessionId}`」。
 *   原因：S12 引入多会话后，单 key 会让切换会话时相互覆盖，离线断网只能看到最后一次
 *   浏览的会话（MoA-2 #05 指出的缺陷）。
 *
 *   迁移策略：
 *     1. 新 key 已存在 → 直接跳过（幂等，支持反复升降级）
 *     2. 否则读旧 key → 补 msg_id → 写新 key
 *     3. 校验新 key 可读且条数一致后才删旧 key
 *     4. 任何一步失败都保留旧 key（降级为可用状态，不阻塞启动）
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { StoredMessage } from '../models/ChatModels.ets';

const STORE_NAME: string = 'xiaoq_preferences';
const KEY_API_KEY: string = 'api_key';
const KEY_DEVICE_ID: string = 'device_id';
/** 旧版单 key（迁移来源，迁移成功后删除） */
const KEY_LEGACY_MESSAGES: string = 'chat_messages';
/** 新版按会话分 key 的前缀 */
const MSG_KEY_PREFIX: string = 'msg_cache_';
const MAX_SAVED_MESSAGES: number = 200;

let preferencesInstance: preferences.Preferences | null = null;

async function getPreferences(context: common.Context): Promise<preferences.Preferences> {
  if (preferencesInstance !== null) {
    return preferencesInstance;
  }
  try {
    preferencesInstance = await preferences.getPreferences(context, STORE_NAME);
    return preferencesInstance;
  } catch (error) {
    console.error('getPreferences failed: ' + error);
    throw new Error('getPreferences failed');
  }
}

// ───────────────────────────── API Key ─────────────────────────────

export async function saveApiKey(context: common.Context, apiKey: string): Promise<void> {
  try {
    const pref: preferences.Preferences = await getPreferences(context);
    await pref.put(KEY_API_KEY, apiKey);
    await pref.flush();
  } catch (error) {
    console.error('saveApiKey failed: ' + error);
  }
}

export async function loadApiKey(context: common.Context): Promise<string> {
  try {
    const pref: preferences.Preferences = await getPreferences(context);
    const valueObj: preferences.ValueType = await pref.get(KEY_API_KEY, '');
    return valueObj as string;
  } catch (error) {
    console.error('loadApiKey failed: ' + error);
    return '';
  }
}

// ─────────────────────── 消息持久化（按会话分 key）───────────────────────

function msgKeyOf(sessionId: string): string {
  return MSG_KEY_PREFIX + sessionId;
}

/** 该会话的新 key 是否已存在（迁移幂等判断用） */
export async function hasSessionMessages(context: common.Context, sessionId: string): Promise<boolean> {
  try {
    const pref: preferences.Preferences = await getPreferences(context);
    const key: string = msgKeyOf(sessionId);
    const exists: boolean = await pref.has(key);
    return exists;
  } catch (error) {
    console.error('hasSessionMessages failed: ' + error);
    return false;
  }
}

export async function saveSessionMessages(context: common.Context, sessionId: string,
  messages: StoredMessage[]): Promise<void> {
  try {
    // 只保留最近 MAX_SAVED_MESSAGES 条
    const toSave: StoredMessage[] = messages.slice(-MAX_SAVED_MESSAGES);
    const json: string = JSON.stringify(toSave);
    const pref: preferences.Preferences = await getPreferences(context);
    await pref.put(msgKeyOf(sessionId), json);
    await pref.flush();
  } catch (error) {
    console.error('saveSessionMessages failed: ' + error);
  }
}

export async function loadSessionMessages(context: common.Context, sessionId: string): Promise<StoredMessage[]> {
  try {
    const pref: preferences.Preferences = await getPreferences(context);
    const valueObj: preferences.ValueType = await pref.get(msgKeyOf(sessionId), '[]');
    const json: string = valueObj as string;
    const result: StoredMessage[] = JSON.parse(json) as StoredMessage[];
    return result;
  } catch (error) {
    console.error('loadSessionMessages failed: ' + error);
    return [];
  }
}

// ───────────────────────── 旧 key（迁移专用）─────────────────────────

export async function loadLegacyMessages(context: common.Context): Promise<StoredMessage[]> {
  try {
    const pref: preferences.Preferences = await getPreferences(context);
    const exists: boolean = await pref.has(KEY_LEGACY_MESSAGES);
    if (!exists) {
      return [];
    }
    const valueObj: preferences.ValueType = await pref.get(KEY_LEGACY_MESSAGES, '[]');
    const json: string = valueObj as string;
    const result: StoredMessage[] = JSON.parse(json) as StoredMessage[];
    return result;
  } catch (error) {
    console.error('loadLegacyMessages failed: ' + error);
    return [];
  }
}

export async function removeLegacyMessages(context: common.Context): Promise<void> {
  try {
    const pref: preferences.Preferences = await getPreferences(context);
    await pref.delete(KEY_LEGACY_MESSAGES);
    await pref.flush();
  } catch (error) {
    console.error('removeLegacyMessages failed: ' + error);
  }
}

// ───────────────────────── 固定设备 ID ─────────────────────────

// 重启后不变，用于 sync_pending 匹配离线缓存
export async function getOrCreateDeviceId(context: common.Context): Promise<string> {
  try {
    const pref: preferences.Preferences = await getPreferences(context);
    const existing: preferences.ValueType = await pref.get(KEY_DEVICE_ID, '');
    const existingStr: string = existing as string;
    if (existingStr !== '') {
      return existingStr;
    }
    // 生成新 ID：时间戳 + 随机数后缀
    const newId: string = 'device-' + Date.now().toString() + '-' + Math.floor(Math.random() * 10000).toString();
    await pref.put(KEY_DEVICE_ID, newId);
    await pref.flush();
    console.info('Created device_id: ' + newId);
    return newId;
  } catch (error) {
    console.error('getOrCreateDeviceId failed: ' + error);
    return 'device-' + Date.now().toString();
  }
}
