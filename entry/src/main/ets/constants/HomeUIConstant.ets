import { SortEnum } from 'data_source';
import { SegmentButtonV2Items } from '@kit.ArkUI';

export const SegBtnItems: SegmentButtonV2Items = new SegmentButtonV2Items([{ text: '备忘' }, { text: '待办' }]);

export enum ToolBarName {
  MOVE = '移动',
  SHARE = '分享',
  DELETE = '删除',
  SELECT_ALL = '全选',
}

export interface ToolBar {
  name: ToolBarName,
  icon: Resource,
}

export const ToolBarList: ToolBar[] = [
  {
    name: ToolBarName.SHARE,
    icon: $r('app.media.share')
  },
  {
    name: ToolBarName.MOVE,
    icon: $r('app.media.arrow_right_folder_circle'),
  },
  {
    name: ToolBarName.DELETE,
    icon: $r('app.media.trash'),
  },
  {
    name: ToolBarName.SELECT_ALL,
    icon: $r('app.media.checkmark_square_on_square'),
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