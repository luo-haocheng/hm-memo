/**
 * 我的页面 - 各种服务信息
 */
export interface MinePageCommonService {
  label: string; // 标签名称
  nextPage?: string; // 跳转到下一页
  icon: ResourceStr; // 图标
}

export const COMMON_SERVICE: Array<MinePageCommonService> = [
  {
    label: '回收站',
    nextPage: 'Trash',
    icon: $r('app.media.trash'),
  },
  {
    label: '设置',
    nextPage: 'Setting',
    icon: $r('app.media.setting'),
  },
  {
    label: '意见反馈',
    nextPage: 'FeedBackChoose',
    icon: $r('app.media.feed_back'),
  }
];