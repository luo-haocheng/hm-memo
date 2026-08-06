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
export class Category {
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