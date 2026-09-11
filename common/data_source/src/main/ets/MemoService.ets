import { IMAGE_DIR_NAME, Memo } from 'memo_editor';
import { KVStore } from 'data_source';
import { CategoryService } from './CategoryService';
import { SortMethodEnum, SystemCategory, UserCategory } from './Model';
import { UIContext } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';

// 孤儿图片回收：true 时只记录日志不删除文件，确认清单无误后再改为 false
const RECLAIM_DRY_RUN = false;

// 备忘图片的扩展名白名单，目录内其余文件一律不处理
const IMAGE_EXTENSIONS = ['.jpg', '.jpeg', '.png', '.webp'];

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
   * 两个备忘列表是否都已完整加载。
   * 孤儿图片回收依赖此标志：列表不完整时删除图片会造成误删
   */
  private isFullyLoaded: boolean = false;

  /**
   * 加载全部备忘（有效备忘 + 回收站）
   * 两个列表都完整加载后才置位 isFullyLoaded
   */
  public async loadAllMemos(kvStore: KVStore) {
    const effectiveLoaded = await this.loadEffectiveMemo(kvStore);
    const deletedLoaded = await this.loadDeleteMemo(kvStore);
    this.isFullyLoaded = effectiveLoaded && deletedLoaded;
  }

  /**
   * 读取有效备忘。返回是否完整读取（false 表示数据源不可用，而非没有数据）
   */
  public async loadEffectiveMemo(kvStore: KVStore): Promise<boolean> {
    const dataList = await kvStore.getAll('EffectiveMemo');
    if (!dataList) {
      console.error('Failed to load effective memos: kv store is unavailable.');
      return false;
    }
    for (let i = 0; i < dataList.length; i++) {
      // 单条记录损坏不影响其余记录：跳过该条，继续加载后面的
      try {
        const serializedMemo = JSON.parse(dataList[i].value as string) as Memo;
        const memo = this.constructMemo(serializedMemo);
        await this.addMemo(memo);

        console.info(`Load effective memo ${memo.id} success.`);
      } catch (error) {
        console.error(`Failed to load effective memo ${dataList[i].key}. Cause: ${JSON.stringify(error)}`);
      }
    }
    return true;
  }

  /**
   * 读取回收站备忘。返回是否完整读取（false 表示数据源不可用，而非没有数据）
   */
  public async loadDeleteMemo(kvStore: KVStore): Promise<boolean> {
    const dataList = await kvStore.getAll('DeleteMemo');
    if (!dataList) {
      console.error('Failed to load deleted memos: kv store is unavailable.');
      return false;
    }
    for (let i = 0; i < dataList.length; i++) {
      // 单条记录损坏不影响其余记录：跳过该条，继续加载后面的
      try {
        const serializedMemo = JSON.parse(dataList[i].value as string) as Memo;
        const memo = this.constructMemo(serializedMemo);
        this.dumpsters.push(memo);

        console.info(`Load delete memo ${memo.id} success.`);
      } catch (error) {
        console.error(`Failed to load deleted memo ${dataList[i].key}. Cause: ${JSON.stringify(error)}`);
      }
    }
    return true;
  }

  /**
   * 回收孤儿图片：删除 memo_images 下不再被任何备忘（含回收站）引用的文件。
   *
   * 安全约束：
   * - 仅在 isFullyLoaded 为 true 时执行 —— 列表不完整时删除会造成误删
   * - 白名单式：先收集全部引用，再遍历目录删除未被引用的（顺序不可颠倒）
   * - 只处理认识的图片扩展名，其余文件一律不动
   * - 内部不抛异常，可由调用方 fire-and-forget
   */
  public reclaimOrphanImages(uiContext: UIContext) {
    if (!this.isFullyLoaded) {
      console.info('Skip reclaiming orphan images: memos are not fully loaded.');
      return;
    }
    const context = uiContext.getHostContext();
    if (context === undefined) {
      console.error('Failed to reclaim orphan images: host context is unavailable.');
      return;
    }
    const dir = `${context.filesDir}/${IMAGE_DIR_NAME}`;
    try {
      if (!fileIo.accessSync(dir)) {
        // 从未插入过图片，属于正常情况
        return;
      }
    } catch (error) {
      console.info(`Failed to access directory: ${JSON.stringify(error)}`);
      return;
    }

    // 1. 白名单：收集所有被引用的文件名（有效备忘 + 回收站）
    const referenced = new Set<string>();
    for (const memo of this.memoList) {
      memo.collectImageFileNames(referenced);
    }
    for (const memo of this.dumpsters) {
      memo.collectImageFileNames(referenced);
    }

    // 2. 扫描目录
    let fileNames: string[] = [];
    try {
      fileNames = fileIo.listFileSync(dir);
    } catch (error) {
      console.error(`Failed to list image dir: ${dir}. Cause: ${JSON.stringify(error)}`);
      return;
    }

    // 3. 逐个比对，删除未被引用的
    let removedCount = 0;
    for (const rawName of fileNames) {
      // 防御性截取目录前缀：即使接口返回的是完整路径也能正确取到文件名
      const fileName = rawName.substring(rawName.lastIndexOf('/') + 1);
      if (referenced.has(fileName) || !isImageFileName(fileName)) {
        continue;
      }
      const path = `${dir}/${fileName}`;
      try {
        const size = fileIo.statSync(path).size;
        if (RECLAIM_DRY_RUN) {
          console.info(`[reclaim] would remove orphan image: ${fileName} (${size} bytes)`);
        } else {
          fileIo.unlinkSync(path);
          console.info(`[reclaim] removed orphan image: ${fileName} (${size} bytes)`);
        }
        removedCount++;
      } catch (error) {
        // 删不掉最多留个孤儿，下次回收再试
        console.error(`Failed to remove orphan image: ${path}. Cause: ${JSON.stringify(error)}`);
      }
    }
    console.info(`[reclaim] orphan images ${RECLAIM_DRY_RUN ? 'to remove' : 'removed'}: `
      + `${removedCount}, kept: ${referenced.size}.`);
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
      await putMemoInKvStore(memo, kvStore, 'EffectiveMemo');
    }
  }

  /**
   * 更新笔记
   */
  public updateMemo(memo: Memo, kvStore?: KVStore, uiContext?: UIContext) {
    const index = this.memoList.findIndex((item) => item.id === memo.id);
    this.memoList.splice(index, 1, memo);

    if (kvStore && uiContext) {
      putMemoInKvStore(memo, kvStore, 'EffectiveMemo');
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
    memo.categoryId = '-1';
    this.dumpsters.splice(index, 1);
    this.memoList.push(memo);
    // 更新分类计数
    const category = this.categoryService.getCategoryById(memo.categoryId);
    if (category) {
      category.memoCount++;
    }
    // 持久化
    if (kvStore && uiContext) {
      deleteMemoInKvStore(id, 'DeleteMemo', kvStore);
      putMemoInKvStore(memo, kvStore, 'EffectiveMemo');
    }
  }

  /**
   * 移动笔记分类
   */
  public updateMemoCategory(categoryId: string, kvStore: KVStore) {
    this.memoList
      .filter(memo => memo.categoryId === categoryId)
      .forEach(memo => {
        this.categoryService.moveCategory(memo, '-1');
        memo.categoryId = '-1';
        deleteMemoInKvStore(memo.id, 'EffectiveMemo', kvStore);
        putMemoInKvStore(memo, kvStore, 'EffectiveMemo');
      });
  }

  /**
   * 收藏/取消收藏备忘
   */
  public collectMemo(memoId: string, isFavorite: boolean, kvStore?: KVStore, uiContext?: UIContext) {
    const memo = this.memoList.find(item => item.id === memoId);
    if (!memo) {
      return;
    }
    memo.isFavorite = isFavorite;

    if (kvStore && uiContext) {
      putMemoInKvStore(memo, kvStore, 'EffectiveMemo');
    }
  }

  /**
   * 置顶/取消置顶备忘
   */
  public pinMemo(memoId: string, pinTime: string, kvStore?: KVStore, uiContext?: UIContext) {
    const memo = this.memoList.find(item => item.id === memoId);
    if (!memo) {
      return;
    }
    memo.pinTime = pinTime;

    if (kvStore && uiContext) {
      putMemoInKvStore(memo, kvStore, 'EffectiveMemo');
    }
  }

  /**
   * 启用/移除备忘锁
   */
  public lockMemo(memoId: string, isLocked: boolean, kvStore?: KVStore, uiContext?: UIContext) {
    const memo = this.memoList.find(item => item.id === memoId);
    if (!memo) {
      return;
    }
    memo.isLocked = isLocked;

    if (kvStore && uiContext) {
      putMemoInKvStore(memo, kvStore, 'EffectiveMemo');
    }
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
      putMemoInKvStore(delMemo, kvStore, 'DeleteMemo');
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
   * 根据Id获取回收站备忘
   */
  public getDeletedMemoById(id: string): Memo | undefined {
    if (id === '') {
      return undefined;
    }

    return this.dumpsters.find((item) => item.id === id);
  }

  /**
   * 根据关键词搜索关联笔记
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
      case SystemCategory.DELETED_MEMO:
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
  public getMemoList(id?: string, sortType?: SortMethodEnum, keyWord: string = '') {
    let memoList: Memo[] = this.search(keyWord);
    if (id !== undefined && id !== '-1') {
      memoList = memoList.filter((item) => item.categoryId === id);
    }
    if (sortType === SortMethodEnum.CREATE_TIME) {
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

  private constructMemo(serializedMemo: Memo) {
    const memo = new Memo();
    memo.id = serializedMemo.id;
    memo.title = serializedMemo.title;
    memo.pinTime = serializedMemo.pinTime;
    memo.isLocked = serializedMemo.isLocked;
    memo.isFavorite = serializedMemo.isFavorite;
    memo.categoryId = serializedMemo.categoryId;
    memo.createTime = serializedMemo.createTime;
    memo.updateTime = serializedMemo.updateTime;
    memo.description = serializedMemo.description;
    // 兼容历史数据：Span 迁移前的记录没有 memoBlockArr 字段，缺失或非法时回落为空数组
    memo.memoBlockArr = Array.isArray(serializedMemo.memoBlockArr) ? serializedMemo.memoBlockArr : [];
    return memo;
  }
}

/**
 * 判断是否为备忘图片文件（按扩展名）
 */
function isImageFileName(fileName: string): boolean {
  const lowerName = fileName.toLowerCase();
  return IMAGE_EXTENSIONS.some((ext) => lowerName.endsWith(ext));
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
async function putMemoInKvStore(memo: Memo, kvStore: KVStore, prefix: string) {
  let key = prefix + '_' + memo.id;
  kvStore.put(key, JSON.stringify(memo).replace(/__ob_/g, ''));
}