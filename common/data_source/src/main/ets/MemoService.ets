import { Memo } from 'memo_editor';
import { KVStore, SerializeUtil } from 'serializer';
import { CategoryService } from './CategoryService';
import { SortEnum } from './Model';

@ObservedV2
export class MemoService {
  private static _instance: MemoService;
  private categoryService: CategoryService = CategoryService.instance;

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

    const category = this.categoryService.getCategoryList().find((item) => item.id === memo.categoryId);
    if (category) {
      category.totalCount++;
      if (category.id === '-1') {
        this.categoryService.getCategoryList()[0].totalCount++;
      }
    }

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
   * 移动笔记分类
   */
  public moveMemoCategory(categoryId: string, kvStore: KVStore, uiContext: UIContext) {
    this.memoList.filter(memo => memo.categoryId === categoryId).forEach(memo => {
      memo.categoryId = '-1';

      deleteMemoInKvStore(memo.id, 'EffectiveNote', kvStore);
      putMemoInKvStore(memo, uiContext, kvStore, 'EffectiveNote');
    });
  }

  /**
   * 删除笔记
   */
  public deleteMemo(id: string | undefined, categoryId?: string, kvStore?: KVStore) {
    if (!id) {
      return;
    }
    const index = this.memoList.findIndex((item) => item.id === id);
    this.memoList.splice(index, 1);

    this.categoryService.getCategoryList()[0].totalCount--;
    if (categoryId && categoryId !== '-1') {
      const category = this.categoryService.getCategoryById(categoryId);
      if (category) {
        category.totalCount--;
      }
    }

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
   *
   */
  public search(keyword: string): Memo[] {
    if (!keyword) {
      return this.memoList;
    }

    const lowerKeyword = keyword.toLowerCase();
    return this.memoList.filter((item) => {
      return item.title.toLowerCase().includes(lowerKeyword) || item.description.toLowerCase().includes(lowerKeyword);
    });
  }

  /**
   * 查询笔记列表
   */
  public getMemoList(id?: string, sortType?: SortEnum, keyWord: string = '') {
    let memoList: Memo[] = this.search(keyWord);
    if (id !== undefined && id !== '-1') {
      memoList = memoList.filter((item) => item.categoryId === id);
    }
    if (sortType === SortEnum.CREATE_TIME) {
      memoList = memoList.sort((a, b) => parseInt(b.createTime) - parseInt(a.createTime));
    } else {
      memoList = memoList.sort((a, b) => parseInt(b.updateTime) - parseInt(a.updateTime));
    }

    return memoList;
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