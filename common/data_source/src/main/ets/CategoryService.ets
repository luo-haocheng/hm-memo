import { KVStore, SerializeUtil } from 'serializer';
import { Category } from './Model';
import { Memo } from 'memo_editor';

/**
 * 初始化分类列表
 */
function initCategoryList(): Array<Category> {
  let categoryList: Array<Category> = [];
  categoryList.push(new Category('默认', 0, '-1',));
  console.info(`initCategoryList success.`);
  return categoryList;
}

/**
 * 持久化 保存备忘
 */
function putMemoInKvStore(memo: Memo, uiContext: UIContext, kvStore: KVStore, prefix: string) {
  SerializeUtil.serialize(memo.styledString, uiContext).then(value => {
    let key = prefix + '_' + memo.id;
    memo.serializedStyledString = value;
    kvStore.put(key, JSON.stringify(memo).replace(/__ob_/g, ''));
  });
}

@ObservedV2
export class CategoryService {
  private static _instance: CategoryService;

  public static get instance() {
    if (!CategoryService._instance) {
      CategoryService._instance = new CategoryService();
    }
    return CategoryService._instance;
  }

  /**
   * 初始化分类数据
   */
  @Trace private categoryList: Array<Category> = initCategoryList();

  /**
   * 加载分类列表
   */
  public async loadCategoryList(kvStore: KVStore, memoList: Array<Memo>) {
    const dataList = await kvStore.getAll('Category_');
    if (dataList) {
      for (let i = 0; i < dataList.length; i++) {
        const category = JSON.parse(dataList[i].value as string) as Category;
        this.categoryList.push(category);

        console.info(`Load category ${category.id} success.`);
      }
      console.info(`Load category success.`);
    }
    this.resetMemoCount(memoList);
  }

  private resetMemoCount(memoList: Array<Memo>) {
    this.categoryList.forEach((category) => {
      category.memoCount = 0;
    });
    const defaultCategory = this.categoryList.find(category => category.id === '-1');
    if (defaultCategory) {
      defaultCategory.memoCount = memoList.length;
    }
    memoList.filter((memo) => {
      const matchedCategory = this.categoryList.find(category => category.id === memo.categoryId);
      if (matchedCategory) {
        matchedCategory.memoCount += 1;
        console.info(
          `Increment memo count for category ${matchedCategory.id}, new count: ${matchedCategory.memoCount}`);
      }
    });
  }

  /**
   * 获取所有分类
   */
  getCategoryList(): Array<Category> {
    return this.categoryList;
  }

  /**
   * 获取指定ID的分类
   */
  getCategoryById(id: string): Category | undefined {
    return this.categoryList.find((item) => item.id === id);
  }

  /**
   * 获取第一个分类
   */
  getFirstCategory(): Category {
    return this.categoryList[0];
  }

  /**
   * 新增分类
   */
  addCategory(category: Category, kvStore: KVStore, uiContext: UIContext): boolean {
    const isDuplicateCategory = this.categoryList.find((item) => item.name === category.name);
    if (isDuplicateCategory) {
      try {
        uiContext.getPromptAction().showToast({
          message: '已存在同名分类，请重新创建分类',
          alignment: Alignment.Center,
          duration: 1500,
        });
      } catch (error) {
        console.error(`Failed to showToast when add category. Cause: ${JSON.stringify(error)}`);
      }
      return false;
    }
    this.categoryList.push(new Category(category.name, category.memoCount));

    kvStore.put('Category_' + category.id, JSON.stringify(category).replace(/__ob_/g, ''));

    return false;
  }

  /**
   * 更新分类
   */
  updateCategory(category: Category, kvStore: KVStore) {
    const idx = this.categoryList.findIndex((item) => item.id === category.id);
    if (idx === -1) {
      return;
    }
    const target = this.categoryList[idx];
    this.categoryList.splice(idx, 1, new Category(category.name, target.memoCount, target.id));
    console.info(`Category List: ${JSON.stringify(this.categoryList)}`);
    // target.name = category.name;
    kvStore.put(`Category_` + category.id, JSON.stringify(category).replace(/__ob_/g, ''));
  }

  /**
   * 删除指定Id的分类
   */
  deleteCategoryById(categoryId: string, kvStore: KVStore) {
    let index = this.categoryList.findIndex((item) => item.id === categoryId);
    if (index !== -1) {
      this.categoryList.splice(index, 1);
      kvStore.delete('Category_' + categoryId);
    }
  }

  /**
   * 移动分类
   */
  moveCategory(memo: Memo, targetCategoryId: string, kvStore: KVStore, uiContext: UIContext) {
    const originalCategoryId = memo.categoryId;
    if (originalCategoryId === targetCategoryId) {
      return;
    }

    if (originalCategoryId !== '-1') {
      let originalCategory = this.getCategoryById(originalCategoryId);
      if (originalCategory) {
        originalCategory.memoCount--;
        kvStore.put('Category_' + originalCategory.id, JSON.stringify(originalCategory).replace('/__ob_/g', ''));
      }
    }

    let targetCategory = this.getCategoryById(targetCategoryId);
    if (targetCategory) {
      if (targetCategory.id !== '-1') {
        targetCategory.memoCount++;
        kvStore.put('Category_' + targetCategory.id, JSON.stringify(targetCategory).replace('/__ob_/g', ''));
      }
    }

    putMemoInKvStore(memo, uiContext, kvStore, 'EffectiveMemo');
  }
}