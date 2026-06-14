import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME: string = 'xiaoq_preferences';
const KEY_API_KEY: string = 'api_key';

let preferencesInstance: preferences.Preferences | null = null;

async function getPreferences(context: common.Context): Promise<preferences.Preferences> {
  if (preferencesInstance !== null) {
    return preferencesInstance;
  }
  preferencesInstance = await preferences.getPreferences(context, STORE_NAME);
  return preferencesInstance;
}

export async function saveApiKey(context: common.Context, apiKey: string): Promise<void> {
  const pref = await getPreferences(context);
  await pref.put(KEY_API_KEY, apiKey);
  await pref.flush();
}

export async function loadApiKey(context: common.Context): Promise<string> {
  const pref = await getPreferences(context);
  const valueObj: preferences.ValueType = await pref.get(KEY_API_KEY, '');
  const value: string = valueObj as string;
  return value;
}
