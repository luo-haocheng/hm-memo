import { Memo } from 'memo_editor';
import { KVStore, SerializeUtil } from 'serializer';

@ObservedV2
export class MemoService {
  private static _instance: MemoService;

  public static get instance() {
    if (!MemoService._instance) {
      MemoService._instance = new MemoService();
    }
    return MemoService._instance;
  }

  @Trace private memoList: Memo[] = [];

  public async loadEffectiveMemo(kvStore: KVStore) {
    const dataList = await kvStore.getAll('EffectiveMemo');
    if (!dataList) {
      return;
    }
    for (let i = 0; i < dataList.length; i++) {
      const serializedMemo = JSON.parse(dataList[i].value as string) as Memo;
      let mss = await SerializeUtil.deserialize(serializedMemo.serializedStyledString);
      const memo = this.constructMemo(mss, serializedMemo);
      await this.addMemo(memo);
      console.info(`Load memo ${memo.id} success.`);
    }
    console.info(`Load memo data success.`);
  }

  /**
   * 添加笔记
   */
  public async addMemo(memo: Memo, kvStore?: KVStore, uiContext?: UIContext) {
    this.memoList.unshift(memo);

    if (kvStore && uiContext) {
      await putMemoInKvStore(memo, uiContext, kvStore, 'EffectiveMemo');
    }
  }

  /**
   * 更新笔记
   */
  public updateMemo(memo: Memo, kvStore?: KVStore, uiContext?: UIContext) {
    const index = this.memoList.findIndex((item) => item.id === memo.id);
    this.memoList.splice(index, 1, memo);

    if (kvStore && uiContext) {
      putMemoInKvStore(memo, uiContext, kvStore, 'EffectiveMemo');
    }
  }

  /**
   * 删除笔记到回收站
   */
  public deleteMemo(id: string | undefined, kvStore?: KVStore) {
    if (!id) {
      return;
    }
    const index = this.memoList.findIndex((item) => item.id === id);
    this.memoList.splice(index, 1);

    if (kvStore) {
      deleteMemoInKvStore(id, 'EffectiveMemo', kvStore);
    }
  }

  /**
   * 根据Id获取笔记
   */
  public getMemoById(id: string): Memo | undefined {
    if (id === '') {
      return undefined;
    }
    return this.memoList.find((item) => item.id === id);
  }

  /**
   * 查询笔记列表
   */
  public getMemoList() {
    this.memoList.sort((a, b) => parseInt(b.createTime) - parseInt(a.createTime));
    return this.memoList;
  }

  private constructMemo(value: MutableStyledString, serializedMemo: Memo) {
    const memo = new Memo(value);
    memo.id = serializedMemo.id;
    memo.title = serializedMemo.title;
    memo.categoryId = serializedMemo.categoryId;
    memo.createTime = serializedMemo.createTime;
    memo.updateTime = serializedMemo.updateTime;
    memo.description = serializedMemo.description;
    return memo;
  }
}

/**
 * 持久化 删除笔记
 */
function deleteMemoInKvStore(id: string, prefix: string, kvStore: KVStore) {
  const key = prefix + '_' + id;
  kvStore.delete(key);
}

/**
 * 持久化 保存笔记
 */
async function putMemoInKvStore(memo: Memo, uiContext: UIContext, kvStore: KVStore, prefix: string) {
  const data = await SerializeUtil.serialize(memo.styledString, uiContext);
  let key = prefix + '_' + memo.id;
  memo.serializedStyledString = data;
  kvStore.put(key, JSON.stringify(memo).replace(/__ob_/g, ''));
}