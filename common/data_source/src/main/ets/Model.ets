/**
 * 系统备忘分类
 */
export enum SystemCategory {
  ALL_MEMO = '全部备忘',
  FAVORITE_MEMO = '收藏',
  LOCKED_MEMO = '加锁',
  DELETE_MEMO = '最近删除',
}

/**
 * 排序方式
 */
export enum SortEnum {
  /**
   * 按创建时间
   */
  CREATE_TIME = 'createTime',
  /**
   * 按修改时间
   */
  UPDATE_TIME = 'updateTime',
  /**
   * 按进入回收站时间升序（最早在前）
   */
  CREATE_TIME_ASC = 'createTimeAsc',
  /**
   * 按进入回收站时间降序（最晚在前）
   */
  CREATE_TIME_DESC = 'createTimeDesc',
}

/**
 * 分类
 */
@ObservedV2
export class UserCategory {
  /**
   * id
   */
  @Trace id: string = '';
  /**
   * 分类名称
   */
  @Trace name: string = '';
  /**
   * 数量
   */
  @Trace memoCount: number = 0;

  constructor(name: string, memoCount: number, id?: string) {
    this.name = name;
    this.memoCount = memoCount;
    this.id = id ? id : new Date().getTime().toString();
  }
}