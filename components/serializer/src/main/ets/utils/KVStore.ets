import { distributedKVStore } from '@kit.ArkData';
import { bundleManager, common } from '@kit.AbilityKit';

class KVStoreType {
  public key: string;
  public value: Uint8Array | string | number | boolean;
  public type: string;

  constructor(key: string, value: Uint8Array | string | number | boolean, type: string) {
    this.key = key;
    this.value = value;
    this.type = type;
  }
}

export class KVStore {
  kvManager: distributedKVStore.KVManager | undefined = undefined;
  kvStore: distributedKVStore.SingleKVStore | undefined = undefined;
  bundleName: string = '';

  createKVStore(encrypt: boolean, securityLevel: distributedKVStore.SecurityLevel,
    uiContext: UIContext): Promise<distributedKVStore.SingleKVStore> {
    let bundleFlags = bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT;
    let hContext = uiContext.getHostContext() as common.UIAbilityContext;

    // 获取当前应用的Bundle信息
    let data = bundleManager.getBundleInfoForSelfSync(bundleFlags);
    this.bundleName = data.name;

    // 创建KVManager实例
    const kvManagerConfig: distributedKVStore.KVManagerConfig = {
      bundleName: this.bundleName,
      context: hContext,
    };
    this.kvManager = distributedKVStore.createKVManager(kvManagerConfig);

    const options: distributedKVStore.Options = {
      backup: false,
      autoSync: false,
      encrypt: encrypt,
      createIfMissing: true,
      securityLevel: securityLevel,
      kvStoreType: distributedKVStore.KVStoreType.SINGLE_VERSION,
    };

    return new Promise((resolve) => {
      this.kvManager?.getKVStore<distributedKVStore.SingleKVStore>(`${securityLevel}${JSON.stringify(encrypt)}`,
        options, (err, store) => {
          if (err) {
            console.error(`Failed to get KVStore: Code:${err.code},message:${err.message}`);
            return;
          }
          console.info('Succeeded in getting KVStore.');
          resolve(store);
        });
    });
  }

  put(key: string, value: Uint8Array | string | number | boolean) {
    this.kvStore?.put(key, value, (err) => {
      if (err) {
        console.error(`Failed to put data. Code:${err.code},message:${err.message}`);
        return;
      }
      console.info('Succeeded in putting data.');
    });
  }

  delete(key: string) {
    this.kvStore?.delete(key, (err) => {
      if (err) {
        console.error(`Failed to delete data. Code:${err.code},message:${err.message}`);
        return;
      }
      console.info('Succeeded in deleting data.');
    });
  }

  async getAll(key: string): Promise<KVStoreType[] | undefined> {
    if (!this.kvStore) {
      return undefined;
    }
    let allKVStore: KVStoreType[] = [];
    await this.kvStore.getEntries(key)
      .then((entries: distributedKVStore.Entry[]) => {
        for (let i = 0; i < entries.length; i++) {
          let type: string = typeof entries[i].value.value;
          if (type === 'object') {
            type = 'Uint8Array';
          }
          let kvStoreType = new KVStoreType(entries[i].key, entries[i].value.value, type);
          allKVStore.push(kvStoreType);
        }
      })
      .catch((error: BusinessError) => {
        console.error(`Failed to getEntries. Code:${error.code},message:${error.message}`);
      });

    return allKVStore;
  }
}