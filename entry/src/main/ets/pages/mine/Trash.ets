import { MemoService } from 'data_source';
import { KVStore } from 'serializer';
import { Memo } from 'memo_editor';
import { DateUtil } from 'utils';
import { DateConstants } from 'utils/src/main/ets/constants/DateConstants';

@Builder
export function TrashBuilder() {
  Trash();
}

@ComponentV2
export struct Trash {
  private uiContext: UIContext = this.getUIContext() as UIContext;
  private memoService: MemoService = MemoService.instance;
  private scroller: ListScroller = new ListScroller();
  @Consumer('appPathStack') appPathStack: NavPathStack = new NavPathStack();
  @Consumer() kvStore: KVStore | undefined = undefined;
  @Local memoList: Memo[] = this.memoService.getDeletedMemoList();

  @Builder
  swipeEnd(item: Memo) {
    Row() {
      // 恢复按钮
      Column() {
        Image($r('app.media.icon_recover'))
          .width(40)
          .height(40)
          .onClick(() => {
            this.memoService.recoverMemo(item.id, this.kvStore, this.uiContext);
            this.scroller.closeAllSwipeActions();
          });
      }
      .width(60)
      .height(105)
      .justifyContent(FlexAlign.Center);

      // 删除按钮
      Column() {
        Image($r('app.media.delete_category'))
          .width(40)
          .height(40)
          .onClick(() => {
            this.memoService.deletePermanently(item.id, this.kvStore);
            this.scroller.closeAllSwipeActions();
          });
      }
      .width(60)
      .height(105)
      .justifyContent(FlexAlign.Center);
    }
    .height(105);
  }

  @Builder
  showNoteList() {
    List({ space: 12, scroller: this.scroller }) {
      ForEach(
        this.memoList,
        (item: Memo) => {
          ListItem() {
            Column() {
              Text(item.title)
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
                .padding({ top: 12 });

              Text(item.description)
                .maxLines(1)
                .fontSize(14)
                .fontWeight(FontWeight.Regular)
                .fontColor($r('sys.color.font_secondary'))
                .textOverflow({ overflow: TextOverflow.Ellipsis });

              Row() {
                Text(DateUtil.getFormatDateStr(item.createTime, DateConstants.DATE_FORMAT4))
                  .fontSize(12)
                  .fontColor($r('sys.color.font_tertiary'));

                Blank();
              }
              .width('100%');
            }
            .height(105)
            .borderRadius(16)
            .padding({ left: 12, right: 12 })
            .alignItems(HorizontalAlign.Start)
            .justifyContent(FlexAlign.SpaceAround)
            .backgroundColor($r('sys.color.comp_background_list_card'));
          }
          .swipeAction({
            end: {
              builder: () => this.swipeEnd(item),
            }
          });
        },
        (item: Memo) => JSON.stringify(item),
      );
    };
  }

  build() {
    NavDestination() {
      Column() {
        Search({ placeholder: '请输入关键词搜索' })
          .width('100%')
          .margin({ bottom: 12 })
          .placeholderColor($r('sys.color.font_secondary'))
          .placeholderFont({ size: $r('sys.float.Body_L') });

        this.showNoteList();
      }
      .width('100%')
      .height('100%')
      .padding({
        top: 10,
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
      });
    }
    .title('回收站')
    .backgroundColor($r('sys.color.background_secondary'));
  }
}