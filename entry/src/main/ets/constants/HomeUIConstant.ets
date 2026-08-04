import { SortEnum } from 'data_source';

export interface SortType {
  name: string | Resource;
  type: SortEnum;
}

export const sortData: SortType[] = [
  {
    name: '按创建时间排序',
    type: SortEnum.CREATE_TIME,
  },
  {
    name: '按修改时间排序',
    type: SortEnum.UPDATE_TIME,
  }
];

export enum ShowMethodEnum {
  CARD = '1', // 瀑布流方式展示
  LIST = '2', // 常规列表
}

export interface ShowMethod {
  name: string | Resource;
  type: ShowMethodEnum,
}

export const showType: ShowMethod[] = [
  {
    name: '按卡片展示',
    type: ShowMethodEnum.CARD,
  },
  {
    name: '按列表展示',
    type: ShowMethodEnum.LIST,
  }
];