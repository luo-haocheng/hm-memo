/**
 * 系统备忘分类
 */
export enum SystemCategory {
  ALL_MEMO = '全部备忘',
  FAVORITE_MEMO = '收藏',
  LOCKED_MEMO = '加锁',
  DELETED_MEMO = '最近删除',
}

/**
 * 排序方式
 */
export enum SortMethodEnum {
  /**
   * 按创建时间
   */
  CREATE_TIME = 'createTime',
  /**
   * 按修改时间
   */
  UPDATE_TIME = 'updateTime',
}

/**
 * 备忘展示视图选项
 */
export enum ShowMethodEnum {
  Grid = '宫格视图',
  LIST = '列表视图',
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
   * 分类文件夹颜色
   */
  @Trace color: ResourceColor = '#EBAC24';
  /**
   * 数量
   */
  @Trace memoCount: number = 0;

  constructor(name: string, color: ResourceColor, memoCount: number, id?: string) {
    this.name = name;
    this.color = color;
    this.memoCount = memoCount;
    this.id = id ? id : new Date().getTime().toString();
  }
}