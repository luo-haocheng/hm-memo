import { Memo } from 'memo_editor';
import { KVStore } from 'serializer';
import { Category, CategoryService, MemoService } from 'data_source';
import { distributedKVStore } from '@kit.ArkData';
import { DateUtil } from 'utils';
import { DateConstants } from 'utils/src/main/ets/constants/DateConstants';


@Entry
@ComponentV2
struct Index {
  memoService: MemoService = MemoService.instance;
  uiContext: UIContext = this.getUIContext() as UIContext;
  categoryService: CategoryService = CategoryService.instance;
  securityLevel: distributedKVStore.SecurityLevel = distributedKVStore.SecurityLevel.S1;
  @Provider() kvStore: KVStore | undefined = undefined;
  @Provider('appPathStack') appPathStack: NavPathStack = new NavPathStack();
  @Local memoList: Array<Memo> = [];
  @Local openCategorySheet: boolean = false;
  @Local currentCategory: Category = this.categoryService.getFirstCategory();

  async aboutToAppear() {
    // 创建KV数据库
    this.kvStore = new KVStore();
    this.kvStore.kvStore = await this.kvStore.createKVStore(false, this.securityLevel, this.uiContext);
    // 加载备忘数据
    await this.memoService.loadEffectiveMemo(this.kvStore);
    this.memoList = this.memoService.getMemoList();
    // 加载分类数据
    await this.categoryService.loadCategoryList(this.kvStore, this.memoList);

    console.info(`Current Category: ${JSON.stringify(this.currentCategory)}`);

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
  editorMemoList() {
    Row() {
      Row({ space: 4 }) {
        Text(this.currentCategory.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'));

        SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
          .fontColor([$r('sys.color.font_secondary')]);
      }
      .onClick(() => {
        this.openCategorySheet = true;
      })
      .bindSheet(
        $$this.openCategorySheet,
        this.showCategoryDialog(),
        {
          height: 400,
          width: '100%',
          title: { title: '笔记分类' },
          radius: { topLeft: 16, topRight: 16 },
        }
      );

      Blank();

      Image($r('app.media.icon_more'))
        .width(20)
        .height(20);
    }
    .width('100%')
    .padding({
      left: $r('sys.float.padding_level8'),
      right: $r('sys.float.padding_level8'),
      top: 12,
      bottom: 12,
    });
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
      const params: Record<string, Object> = { 'memoId': '', 'currentCategory': this.currentCategory };
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
      const params: Record<string, Object> = { 'memoId': item.id, 'currentCategory': this.currentCategory };
      this.appPathStack.pushPathByName('MemoEdit', params);
    });
  }

  @Builder
  cardItemEnd(memo: Memo) {
    Row() {
      Image($r('app.media.trash_fill'))
        .width(40)
        .height(40)
        .padding(8)
        .borderRadius('50%')
        .fillColor(Color.White)
        .backgroundColor(Color.Red)
        .onClick(() => {
          this.memoService.deleteMemo(memo.id, memo.categoryId, this.kvStore);
        });
    }
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.SpaceAround)
    .padding($r('sys.float.padding_level8'));
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
            }
            .swipeAction({
              end: {
                builder: () => {
                  this.cardItemEnd(item);
                }
              }
            });
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

  @Builder
  showCategoryDialog() {
    Column() {
      Column() {
        List() {
          ForEach(
            this.categoryService.getCategoryList(),
            (category: Category, index: number) => {
              ListItem() {
                Column() {
                  if (index !== 0) {
                    Divider()
                      .color($r('sys.color.comp_divider'));
                  }

                  Row() {
                    Text(category.name)
                      .fontSize(16)
                      .fontColor(this.currentCategory.id === category.id ?
                        $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
                      .fontWeight(this.currentCategory.id === category.id ? FontWeight.Medium : FontWeight.Regular);

                    Blank();

                    Text(String(category.totalCount))
                      .fontSize(16);
                  }
                  .height(50)
                  .width('100%');
                };
              }
              .padding({ left: 12, right: 12 })
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .onClick(() => {
                // todo
              });
            },
            (category: Category) => category.id,
          );
        }
        .borderRadius(8)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None);
      }
      .height(250);

      Blank();

      Button() {
        Row() {
          Text('前往笔记分类')
            .fontWeight(FontWeight.Medium)
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('sys.color.font_on_primary'));

          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(18)
            .fontColor([Color.White])
            .fontWeight(FontWeight.Medium)
            .padding({ left: 12 });
        };
      }
      .height(40)
      .width('100%')
      .margin({ bottom: 30 })
      .backgroundColor('#FFAA00')
      .onClick(() => {
        this.openCategorySheet = false;
        if (this.currentCategory) {
          const params: Record<string, Object | undefined> =
            { 'isEditCategory': true, 'currentCategory': this.currentCategory };
          this.appPathStack.pushPathByName('EditCategory', params);
        }
      });
    }
    .height(344)
    .margin({
      left: $r('sys.float.padding_level8'),
      right: $r('sys.float.padding_level8'),
    })
    .backgroundColor($r('sys.color.background_secondary'));
  }

  build() {
    Navigation(this.appPathStack) {
      Column() {
        // 顶部栏
        this.headerArea();
        // 搜索栏
        this.searchBar();
        // 工具栏
        this.editorMemoList();
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