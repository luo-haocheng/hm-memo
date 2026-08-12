import { SegmentButtonV2Items } from '@kit.ArkUI';

export const SegBtnItems: SegmentButtonV2Items = new SegmentButtonV2Items([{ text: '备忘' }, { text: '待办' }]);

export enum ToolBarName {
  MOVE = '移动',
  DELETE = '删除',
  RECOVER = '恢复',
  SELECT_ALL = '全选',
}

export interface ToolBar {
  name: ToolBarName,
  icon: Resource,
}

export const NormalToolBarList: ToolBar[] = [
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

export const DeleteToolBarList: ToolBar[] = [
  {
    name: ToolBarName.DELETE,
    icon: $r('app.media.trash'),
  },
  {
    name: ToolBarName.RECOVER,
    icon: $r('app.media.arrow_counterclockwise')
  },
  {
    name: ToolBarName.SELECT_ALL,
    icon: $r('app.media.checkmark_square_on_square'),
  },
];
