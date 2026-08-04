import { Memo } from 'memo_editor';
import { KVStore } from 'serializer';
import { Category, CategoryService, MemoService, SortEnum } from 'data_source';
import { distributedKVStore } from '@kit.ArkData';
import { DateUtil } from 'utils';
import { DateConstants } from 'utils/src/main/ets/constants/DateConstants';
import { ShowMethod, ShowMethodEnum, showType, sortData, SortType } from '../constants/HomeUIConstant';


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
  @Local searchKeyword: string = '';
  @Local isSearching: boolean = false;
  @Local openSortSheet: boolean = false;
  @Local openCategorySheet: boolean = false;
  @Local sortBy: SortEnum = SortEnum.CREATE_TIME;
  @Local showListType: ShowMethodEnum = ShowMethodEnum.LIST;
  @Local currentCategory: Category = this.categoryService.getFirstCategory();

  async aboutToAppear() {
    // 创建KV数据库
    this.kvStore = new KVStore();
    this.kvStore.kvStore = await this.kvStore.createKVStore(false, this.securityLevel, this.uiContext);
    // 加载备忘数据
    await this.memoService.loadEffectiveMemo(this.kvStore);
    await this.memoService.loadDeleteMemo(this.kvStore);
    // 填充备忘列表
    this.memoList = this.memoService.getMemoList();
    // 加载分类数据
    await this.categoryService.loadCategoryList(this.kvStore, this.memoList);

    console.info(`Current Category: ${JSON.stringify(this.currentCategory)}`);

  }

  resetCategory(category: Category) {
    this.currentCategory = category;
    this.memoList = this.memoService.getMemoList(this.currentCategory.id);
    this.openCategorySheet = false;
  }

  // 搜索
  onSearch(categoryId: string, keyword: string, sortBy: SortEnum): Memo[] {
    this.searchKeyword = keyword.trim();
    this.isSearching = this.searchKeyword.length > 0;
    return this.memoService.getMemoList(categoryId, sortBy, this.searchKeyword);
  }

  // 排序确认方法
  onSortConfirm(categoryId: string, sortBy: SortEnum, searchKeyword: string) {
    this.sortBy = sortBy;
    this.memoService.getMemoList(categoryId, this.sortBy, searchKeyword);
    this.openSortSheet = false;
  }

  // 列表排序
  sort = (type: SortEnum) => {
    this.onSortConfirm(this.currentCategory.id, type, '');
  };
  // 列表展开方式
  toggleShowType = (userWaterFlow: ShowMethodEnum) => {
    this.showListType = userWaterFlow;
    this.openSortSheet = false;
  };

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
        .height(40)
        .onClick(() => {
          this.appPathStack.pushPathByName('MineView', undefined);
        });
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
      .margin({ bottom: 12, left: $r('sys.float.padding_level8'), right: $r('sys.float.padding_level8') })
      .onSubmit((value: string) => {
        // 提交搜索
        this.memoList = this.onSearch(this.currentCategory.id, value, this.sortBy);
      })
      .onChange((value: string) => {
        if (!value) {
          // 清空搜索时恢复列表
          this.memoList = this.onSearch(this.currentCategory.id, '', this.sortBy);
        }
      });
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
        .height(20)
        .onClick(() => {
          this.openSortSheet = true;
        })
        .bindSheet(
          $$this.openSortSheet,
          this.sortSheet(),
          {
            height: 376,
            width: '100%',
            showClose: false,
            radius: { topLeft: 16, topRight: 16 },
          }
        );
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
    Row({ space: 8 }) {
      Image($r('app.media.arrow_right_folder_fill'))
        .width(40)
        .height(40)
        .padding(8)
        .borderRadius('50%')
        .fillColor(Color.White)
        .backgroundColor(Color.Green)
        .onClick(() => {
          const params: Record<string, Object> =
            {
              'isEditCategory': false,
              'currentCategory': this.currentCategory,
              'memoList': [memo],
              'resetCategory': () => {
                this.resetCategory(this.currentCategory);
              }
            };
          this.appPathStack.pushPathByName('CategoryEdit', params);
        });

      Image($r('app.media.trash_fill'))
        .width(40)
        .height(40)
        .padding(8)
        .borderRadius('50%')
        .fillColor(Color.White)
        .backgroundColor(Color.Red)
        .onClick(() => {
          this.memoService.deleteMemoToTrash(memo.id, memo.categoryId, this.kvStore, this.uiContext);
        });
    }
    .alignItems(VerticalAlign.Center)
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
          (item: Memo) => JSON.stringify(item),
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
  waterCardList() {
    Column() {
      WaterFlow() {
        ForEach(
          this.memoList,
          (item: Memo) => {
            FlowItem() {
              this.cardItem(item, 9);
            }
            .width('100%');
          },
          (item: Memo) => JSON.stringify(item),
        );
      }
      .width('100%')
      .height('100%')
      .rowsGap(16)
      .cachedCount(1)
      .columnsTemplate('1fr 1fr')
      .columnsGap($r('sys.float.padding_level8'));
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
  emptyMemos() {
    Column() {
      Image($r('app.media.empty_memo'))
        .width(120)
        .height(120);

      Text('岁月悠悠，心事悄悄，记录一下吧')
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'));
    }
    .height(100)
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({
      top: 10,
      left: $r('sys.float.padding_level8'),
      right: $r('sys.float.padding_level8'),
    });
  }

  @Builder
  searchNoResult() {
    Column() {
      Text('没有匹配的备忘')
        .fontSize(16)
        .fontColor($r('sys.color.font_tertiary'));
    }
    .height(100)
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({
      left: $r('sys.float.padding_level8'),
      right: $r('sys.float.padding_level8'),
    });
  }

  @Builder
  showMemoList() {
    if (this.isSearching && this.memoList.length === 0) {
      this.searchNoResult();
    } else if (!this.isSearching && this.memoList.length === 0) {
      this.emptyMemos();
    } else if (this.showListType === ShowMethodEnum.LIST) {
      this.cardList();
    } else {
      this.waterCardList();
    }
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
                this.resetCategory(category);
              });
            },
            (category: Category) => JSON.stringify(category),
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
          this.appPathStack.pushPathByName('CategoryEdit', params);
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

  @Builder
  sheetCard(title: string, data: SortType[] | ShowMethod[], callback: Function, group: string) {
    Column() {
      Text(title)
        .width('100%')
        .margin({ bottom: 16 })
        .fontSize(20)
        .textAlign(TextAlign.Start)
        .fontWeight(FontWeight.Medium);

      List({ space: 24 }) {
        ForEach(
          data,
          (item: SortType | ShowMethod) => {
            ListItem() {
              Row() {
                Text(item.name)
                  .fontSize(16)
                  .fontColor($r('sys.color.font_primary'));

                Blank();

                Radio({ value: item.type, group: group })
                  .checked(this.sortBy === item.type || this.showListType === item.type)
                  .onChange((isChecked: boolean) => {
                    if (isChecked) {
                      callback(item.type);
                    }
                  });
              }
              .width('100%')
              .padding({ left: 12, right: 12 })
              .onClick(() => {
                callback(item.type);
              });
            };
          },
          (item: SortType | ShowMethod) => JSON.stringify(item),
        );
      }
      .borderRadius(8)
      .padding({ top: 16, bottom: 16 })
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .divider({ strokeWidth: 1, startMargin: 12, endMargin: 12 });
    }
    .width('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .padding({
      top: 20,
      left: $r('sys.float.padding_level8'),
      right: $r('sys.float.padding_level8'),
    });
  }

  @Builder
  sortSheet() {
    Column() {
      this.sheetCard('展示形式', showType, this.toggleShowType, 'showType');
      this.sheetCard('排序方式', sortData, this.sort, 'sortGroup');
    };
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
        this.showMemoList();
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