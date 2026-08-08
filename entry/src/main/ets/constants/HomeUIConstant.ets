import { SortEnum } from 'data_source';
import { SegmentButtonV2Items } from '@kit.ArkUI';

export const SegBtnItems: SegmentButtonV2Items = new SegmentButtonV2Items([{ text: '备忘' }, { text: '待办' }]);

export enum ToolBarName {
  MOVE_CATEGORY = '移动到分类',
  DELETE = '删除',
  SELECT_ALL = '全选',
}

export interface ToolBar {
  name: ToolBarName,
  icon: Resource,
}

export const toolBarList: ToolBar[] = [
  {
    name: ToolBarName.MOVE_CATEGORY,
    icon: $r('app.media.move_category'),
  },
  {
    name: ToolBarName.SELECT_ALL,
    icon: $r('app.media.select_all'),
  },
  {
    name: ToolBarName.DELETE,
    icon: $r('app.media.delete'),
  },
];

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