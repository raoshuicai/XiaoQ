import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME: string = 'xiaoq_preferences';
const KEY_API_KEY: string = 'api_key';
const KEY_MESSAGES: string = 'chat_messages';
const KEY_DEVICE_ID: string = 'device_id';
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
    const value: string = valueObj as string;
    return value;
  } catch (error) {
    console.error('loadApiKey failed: ' + error);
    return '';
  }
}

// === 聊天消息持久化 ===

export interface StoredMessage {
  role: string;
  content: string;
}

export async function saveMessages(context: common.Context, messages: StoredMessage[]): Promise<void> {
  try {
    // 只保留最近 MAX_SAVED_MESSAGES 条
    const toSave: StoredMessage[] = messages.slice(-MAX_SAVED_MESSAGES);
    const json: string = JSON.stringify(toSave);
    const pref: preferences.Preferences = await getPreferences(context);
    await pref.put(KEY_MESSAGES, json);
    await pref.flush();
  } catch (error) {
    console.error('saveMessages failed: ' + error);
  }
}

export async function loadMessages(context: common.Context): Promise<StoredMessage[]> {
  try {
    const pref: preferences.Preferences = await getPreferences(context);
    const valueObj: preferences.ValueType = await pref.get(KEY_MESSAGES, '[]');
    const json: string = valueObj as string;
    const result: StoredMessage[] = JSON.parse(json) as StoredMessage[];
    return result;
  } catch (error) {
    console.error('loadMessages failed: ' + error);
    return [];
  }
}

// === 固定设备 ID（重启后不变，用于 sync_pending 匹配离线缓存）===

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
