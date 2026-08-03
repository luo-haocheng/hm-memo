import { Memo } from 'memo_editor';
import { KVStore } from 'serializer';
import { MemoService } from 'data_source';
import { distributedKVStore } from '@kit.ArkData';
import { DateUtil } from 'utils';
import { DateConstants } from 'utils/src/main/ets/constants/DateConstants';

@Entry
@ComponentV2
struct Index {
  @Provider() kvStore: KVStore | undefined = undefined;
  @Provider('appPathStack') appPathStack: NavPathStack = new NavPathStack();
  @Local memoList: Array<Memo> = [];
  memoService: MemoService = MemoService.instance;
  uiContext: UIContext = this.getUIContext() as UIContext;
  securityLevel: distributedKVStore.SecurityLevel = distributedKVStore.SecurityLevel.S1;

  async aboutToAppear() {
    // 创建KV数据库
    this.kvStore = new KVStore();
    this.kvStore.kvStore = await this.kvStore.createKVStore(false, this.securityLevel, this.uiContext);
    // 读取笔记
    await this.memoService.loadEffectiveNote(this.kvStore);
    this.memoList = this.memoService.getNoteList();
    console.info(`Memo List: ${JSON.stringify(this.memoList)}`);
  }

  @Builder
  headerArea() {
    Row() {
      Text('首页')
        .fontSize(24)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'));
      Blank();
      Image($r('app.media.user_avatar'))
        .width(40)
        .height(40);
    }
    .width('100%')
    .padding({
      top: 12,
      bottom: 20,
      left: $r('sys.float.padding_level8'),
      right: $r('sys.float.padding_level8'),
    });
  }

  @Builder
  searchBar() {
    Search({ placeholder: '搜索' })
      .placeholderFont({ size: $r('sys.float.Body_L') })
      .placeholderColor($r('sys.color.font_secondary'))
      .fontColor($r('sys.color.font_primary'))
      .margin({ bottom: 12, left: $r('sys.float.padding_level8'), right: $r('sys.float.padding_level8') });
  }

  @Builder
  addMemoBuilder() {
    Row() {
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize(35)
        .fontColor([Color.White]);
    }
    .width(50)
    .height(50)
    .zIndex(10)
    .borderRadius('50%')
    .backgroundColor('#FFAA00')
    .justifyContent(FlexAlign.Center)
    .position({ right: 32, bottom: 40 })
    .onClick(() => {
      const params: Record<string, Object> = { 'noteId': '' };
      this.appPathStack.pushPathByName('MemoEdit', params);
    });
  }

  @Builder
  cardItem(item: Memo, maxLines: number) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column({ space: 12 }) {
        Text(item.title)
          .maxLines(1)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .textOverflow({ overflow: TextOverflow.Ellipsis });

        Text(item.description)
          .fontSize(14)
          .lineHeight(21)
          .maxLines(maxLines)
          .fontWeight(FontWeight.Regular)
          .fontColor($r('sys.color.font_secondary'))
          .textOverflow({ overflow: TextOverflow.Ellipsis });

        Text(DateUtil.getFormatDateStr(item.createTime, DateConstants.DATE_FORMAT4))
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'));
      }
      .padding(12)
      .width('100%')
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('sys.color.comp_background_list_card'));
    }
    .onClick(() => {
      const params: Record<string, Object> = { 'noteId': item.id };
      this.appPathStack.pushPathByName('MemoEdit', params);
    });
  }

  @Builder
  cardList() {
    Column() {
      List({ space: 12 }) {
        ForEach(
          this.memoList,
          (item: Memo) => {
            ListItem() {
              this.cardItem(item, 1);
            };
          },
          (item: Memo) => item.id,
        );
      }
      .scrollBar(BarState.Off);
    }
    .width('100%')
    .layoutWeight(1)
    .margin({ bottom: 10 })
    .padding({
      left: $r('sys.float.padding_level8'),
      right: $r('sys.float.padding_level8'),
    });
  }

  build() {
    Navigation(this.appPathStack) {
      Column() {
        // 顶部栏
        this.headerArea();
        // 搜索栏
        this.searchBar();
        // 备忘列表
        this.cardList();
        // 新增备忘按钮
        this.addMemoBuilder();
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.background_secondary'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM, SafeAreaEdge.TOP]);
    }
    .hideTitleBar(true)
    .mode(NavigationMode.Stack);
  }
}