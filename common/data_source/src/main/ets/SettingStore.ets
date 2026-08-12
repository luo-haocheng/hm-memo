import { preferences } from '@kit.ArkData';
import { bundleManager, common } from '@kit.AbilityKit';

export class SettingStore {
  settingPreference?: preferences.Preferences;
  bundleName: string = '';

  createPreference(uiContext: UIContext) {
    let bundleFlags = bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT;
    let hContext = uiContext.getHostContext() as common.UIAbilityContext;

    // 获取当前应用的Bundle信息
    let data = bundleManager.getBundleInfoForSelfSync(bundleFlags);
    this.bundleName = data.name;

    console.info(`Bundle Name: ${this.bundleName}`);

    try {
      this.settingPreference = preferences.getPreferencesSync(hContext, { name: this.bundleName });
    } catch (error) {
      console.error(`Failed to invoke preferences.getPreferencesSync. Cause: ${JSON.stringify(error)}`);
    }
  }

  async put(key: string, value: preferences.ValueType) {
    if (!this.settingPreference) {
      console.error(`Failed to put ${key}. setting preference is undefined`);
      return;
    }
    try {
      await this.settingPreference.put(key, value);
      await this.settingPreference.flush();
    } catch (error) {
      console.error(`Failed to invoke preference.put. Cause: ${JSON.stringify(error)}`);
    }
  }

  async get(key: string): Promise<preferences.ValueType | undefined> {
    if (!this.settingPreference) {
      console.error(`Failed to get ${key}. setting preference is undefined`);
      return undefined;
    }
    const value = await this.settingPreference.get(key, undefined);
    return value;
  }
}