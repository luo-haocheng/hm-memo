import { ShowMethodEnum, SortMethodEnum } from './Model';
import { SettingStore } from './SettingStore';

@ObservedV2
export class SettingService {
  private static _instance: SettingService;
  @Trace isGroupByDate: boolean = false;
  @Trace memoShowMethod: ShowMethodEnum = ShowMethodEnum.LIST;
  @Trace memoSortMethod: SortMethodEnum = SortMethodEnum.UPDATE_TIME;

  public static get instance() {
    if (!SettingService._instance) {
      SettingService._instance = new SettingService();
    }
    return SettingService._instance;
  }

  async loadUserSetting(settingStore: SettingStore) {
    const isGroupByDate = await settingStore.get('IsGroupByDate');
    if (isGroupByDate) {
      this.isGroupByDate = isGroupByDate as boolean;
    }
    const memoShowMethod = await settingStore.get('MemoShowMethod');
    if (memoShowMethod) {
      this.memoShowMethod = memoShowMethod as ShowMethodEnum;
    }
    const memoSortMethod = await settingStore.get('MemoSortMethod');
    if (memoSortMethod) {
      this.memoSortMethod = memoSortMethod as SortMethodEnum;
    }
  }

  async setIsGroupByDate(settingStore: SettingStore, value: boolean) {
    this.isGroupByDate = value;
    await settingStore.put('IsGroupByDate', value);
  }

  async setMemoShowMethod(settingStore: SettingStore, value: ShowMethodEnum) {
    this.memoShowMethod = value;
    await settingStore.put('MemoShowMethod', value);
  }

  async setMemoSortMethod(settingStore: SettingStore, value: SortMethodEnum) {
    this.memoSortMethod = value;
    await settingStore.put('MemoSortMethod', value);
  }
}