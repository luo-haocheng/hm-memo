import { Memo } from 'memo_editor';
import { KVStore } from 'serializer';
import { MemoService } from 'data_source';
import { distributedKVStore } from '@kit.ArkData';

@Entry
@ComponentV2
struct Index {
  @Provider() kvStore: KVStore | undefined = undefined;
  @Provider('appPathStack') appPathStack: NavPathStack = new NavPathStack();
  memoService: MemoService = MemoService.instance;
  uiContext: UIContext = this.getUIContext() as UIContext;
  securityLevel: distributedKVStore.SecurityLevel = distributedKVStore.SecurityLevel.S1;

  async aboutToAppear() {
    // 创建KV数据库
    this.kvStore = new KVStore();
    this.kvStore.kvStore = await this.kvStore.createKVStore(false, this.securityLevel, this.uiContext);
    // 读取笔记
    this.memoService.loadEffectiveNote(this.kvStore);
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
      this.appPathStack.pushPath({ name: 'MemoEdit' });
    });
  }

  @Builder
  cardItem(item: Memo, maxLines: number) {

  }

  build() {
    Navigation(this.appPathStack) {
      Column() {
        this.headerArea();

        this.searchBar();

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