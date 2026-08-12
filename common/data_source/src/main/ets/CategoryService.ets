import { SystemCategory, UserCategory } from './Model';
import { KVStore } from 'serializer';
import { Memo } from 'memo_editor';

/**
 * 初始化分类列表
 */
function initCategoryList(): Array<UserCategory> {
  let categoryList: Array<UserCategory> = [];
  categoryList.push(new UserCategory('默认', '#EBAC24', 0, '-1'));
  return categoryList;
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
  @Trace categoryList: Array<UserCategory> = initCategoryList();

  /**
   * 加载分类列表
   */
  public async loadCategoryList(kvStore: KVStore, memoList: Array<Memo>) {
    const dataList = await kvStore.getAll('Category_');
    if (dataList) {
      for (let i = 0; i < dataList.length; i++) {
        const category = JSON.parse(dataList[i].value as string) as UserCategory;
        this.categoryList.push(new UserCategory(category.name, category.color, category.memoCount, category.id));

        console.info(`Load category ${category.id} success.`);
      }
    }
    this.resetMemoCount(memoList);
  }

  private resetMemoCount(memoList: Array<Memo>) {
    this.categoryList.forEach((category) => {
      category.memoCount = 0;
    });
    memoList.forEach((memo) => {
      const matchedCategory = this.categoryList.find(category => category.id === memo.categoryId);
      if (matchedCategory) {
        matchedCategory.memoCount += 1;
      } else {
        console.info(`Not Matched Memo Category ID: ${memo.categoryId}, ${memo.id}`);
      }
    });
  }

  /**
   * 获取所有分类
   */
  getCategoryList(): Array<UserCategory> {
    return this.categoryList;
  }

  /**
   * 获取指定ID的分类
   */
  getCategoryById(id: string): UserCategory | undefined {
    return this.categoryList.find((item) => item.id === id);
  }

  /**
   * 获取第一个分类
   */
  getDefaultCategory(): UserCategory {
    return this.categoryList[0];
  }

  isDuplicateCategory(name: string) {
    let dupWithSysCategory = Object.values(SystemCategory).some(item => item === name);
    let dupWithUserCategory = this.categoryList.some(item => name === item.name);
    return dupWithSysCategory || dupWithUserCategory;
  }

  /**
   * 新增分类
   */
  addCategory(category: UserCategory, kvStore: KVStore, uiContext: UIContext): boolean {
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

    this.categoryList.push(category);

    kvStore.put('Category_' + category.id, JSON.stringify(category).replace(/__ob_/g, ''));

    return false;
  }

  /**
   * 更新分类
   */
  updateCategory(category: UserCategory, kvStore: KVStore) {
    const idx = this.categoryList.findIndex((item) => item.id === category.id);
    if (idx === -1) {
      return;
    }

    this.categoryList.splice(idx, 1, category);

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
  moveCategory(memo: Memo, targetCategoryId: string) {
    const originalCategoryId = memo.categoryId;
    if (originalCategoryId === targetCategoryId) {
      return;
    }

    let originalCategory = this.getCategoryById(originalCategoryId);
    if (originalCategory) {
      originalCategory.memoCount--;
    } else {
      return;
    }

    let targetCategory = this.getCategoryById(targetCategoryId);
    if (targetCategory) {
      targetCategory.memoCount++;
    } else {
      return;
    }
  }
}