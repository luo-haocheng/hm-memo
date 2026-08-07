import { Memo } from 'memo_editor';
import { KVStore, SerializeUtil } from 'serializer';
import { CategoryService } from './CategoryService';
import { SortEnum, SystemCategory, UserCategory } from './Model';
import { UIContext } from '@kit.ArkUI';

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

  @Trace memoList: Memo[] = [];
  @Trace dumpsters: Memo[] = [];

  /**
   * 读取有效备忘
   */
  public async loadEffectiveMemo(kvStore: KVStore) {
    const dataList = await kvStore.getAll('EffectiveMemo');
    if (dataList) {
      for (let i = 0; i < dataList.length; i++) {
        const serializedMemo = JSON.parse(dataList[i].value as string) as Memo;
        let mss = await SerializeUtil.deserialize(serializedMemo.serializedStyledString);
        const memo = this.constructMemo(mss, serializedMemo);
        await this.addMemo(memo);
        console.info(`Load effective memo ${memo.id} success.`);
      }
    }
  }

  /**
   * 读取回收站备忘
   */
  public async loadDeleteMemo(kvStore: KVStore) {
    const dataList = await kvStore.getAll('DeleteMemo');
    if (dataList) {
      for (let i = 0; i < dataList.length; i++) {
        const serializedMemo = JSON.parse(dataList[i].value as string) as Memo;
        let mss = await SerializeUtil.deserialize(serializedMemo.serializedStyledString);
        const memo = this.constructMemo(mss, serializedMemo);
        this.dumpsters.push(memo);

        console.info(`Load delete memo ${memo.id} success.`);
      }
    }
  }

  /**
   * 添加笔记
   */
  public async addMemo(memo: Memo, kvStore?: KVStore, uiContext?: UIContext) {
    this.memoList.unshift(memo);

    const category = this.categoryService.getCategoryList().find((item) => item.id === memo.categoryId);
    if (category) {
      category.memoCount++;
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
   * 从回收站恢复
   */
  public recoverMemo(id: string, kvStore?: KVStore, uiContext?: UIContext) {
    const index = this.dumpsters.findIndex((item) => item.id === id);
    if (index === -1) {
      return;
    }
    // 从删除备忘列表移动到有效备忘列表
    const memo = this.dumpsters[index];
    this.dumpsters.splice(index, 1);
    this.memoList.push(memo);
    // 更新分类计数
    const category = this.categoryService.getCategoryById(memo.categoryId);
    if (category) {
      category.memoCount++;
      if (category.id !== '-1') {
        this.categoryService.getCategoryList()[0].memoCount++;
      }
    }
    // 持久化
    if (kvStore && uiContext) {
      deleteMemoInKvStore(id, 'DeleteMemo', kvStore);
      putMemoInKvStore(memo, uiContext, kvStore, 'EffectiveMemo');
    }
  }

  /**
   * 移动笔记分类
   */
  public moveMemoCategory(categoryId: string, kvStore: KVStore, uiContext: UIContext) {
    this.memoList
      .filter(memo => memo.categoryId === categoryId)
      .forEach(memo => {
        memo.categoryId = '-1';
        deleteMemoInKvStore(memo.id, 'EffectiveMemo', kvStore);
        putMemoInKvStore(memo, uiContext, kvStore, 'EffectiveMemo');
      });
  }

  /**
   * 删除笔记
   */
  public deleteMemoToTrash(id: string, categoryId?: string, kvStore?: KVStore, uiContext?: UIContext) {
    // 从有效备忘列表中取出，插入删除备忘列表中
    const index = this.memoList.findIndex((item) => item.id === id);
    if (index === -1) {
      return;
    }
    const delMemo = this.memoList[index];
    this.memoList.splice(index, 1);
    this.dumpsters.push(delMemo);
    // 相应分类数量减一
    if (categoryId) {
      const category = this.categoryService.getCategoryById(categoryId);
      if (category) {
        category.memoCount--;
      }
    }
    // 从有效备忘持久化中删除，持久化到删除备忘
    if (kvStore && uiContext) {
      deleteMemoInKvStore(id, 'EffectiveMemo', kvStore);
      putMemoInKvStore(delMemo, uiContext, kvStore, 'DeleteMemo');
    }
  }

  /**
   * 从回收站彻底删除备忘
   */
  public deletePermanently(id: string, kvStore?: KVStore) {
    const index = this.dumpsters.findIndex((item) => item.id === id);
    if (index === -1) {
      return;
    }
    this.dumpsters.splice(index, 1);
    if (kvStore) {
      deleteMemoInKvStore(id, 'DeleteMemo', kvStore);
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
   * 根据系统分类查询备忘
   */
  getMemosBySystemCategory(sysCategory: SystemCategory): Array<Memo> {
    switch (sysCategory) {
      case SystemCategory.ALL_MEMO:
        return this.memoList;
      case SystemCategory.FAVORITE_MEMO:
        return this.memoList.filter(memo => memo.isFavorite);
      case SystemCategory.LOCKED_MEMO:
        return this.memoList.filter(memo => memo.isLocked);
      case SystemCategory.DELETE_MEMO:
        return this.dumpsters;
    }
  }

  /**
   * 根据用户分类查询备忘
   */
  getMemosByUserCategory(userCategory: UserCategory): Array<Memo> {
    return this.memoList.filter(memo => memo.categoryId === userCategory.id);
  }

  /**
   * 查询备忘列表
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

  /**
   * 在回收站中搜索笔记
   */
  public searchInDumpsters(keyword: string): Memo[] | undefined {
    if (!keyword) {
      return this.dumpsters;
    }
    const lowerKeyword = keyword.toLowerCase();

    return this.dumpsters.filter((item) => {
      return item.title.toLowerCase().includes(lowerKeyword) ||
        item.description.toLowerCase().includes(lowerKeyword);
    });
  }

  /**
   * 获得回收站数据
   */
  public getDeletedMemoList(): Memo[] {
    return this.dumpsters;
  }

  private constructMemo(value: MutableStyledString, serializedMemo: Memo) {
    const memo = new Memo(value);
    memo.id = serializedMemo.id;
    memo.title = serializedMemo.title;
    memo.isLocked = serializedMemo.isLocked;
    memo.isFavorite = serializedMemo.isFavorite;
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