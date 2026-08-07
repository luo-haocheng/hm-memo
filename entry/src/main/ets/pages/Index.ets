import { Memo } from 'memo_editor';
import { KVStore } from 'serializer';
import { CategoryService, MemoService, SortEnum, SystemCategory, UserCategory } from 'data_source';
import { distributedKVStore } from '@kit.ArkData';
import { DateUtil } from 'utils';
import { DateConstants } from 'utils/src/main/ets/constants/DateConstants';
import {
  ShowMethod,
  ShowMethodEnum,
  showType,
  sortData,
  SortType,
  ToolBar,
  toolBarList,
  ToolBarName,
} from '../constants/HomeUIConstant';
import { Binding, ColorMetrics, LengthMetrics, SegmentButtonV2Items, TabSegmentButtonV2, UIUtils } from '@kit.ArkUI';


@Entry
@ComponentV2
struct Index {
  memoService: MemoService = MemoService.instance;
  uiContext: UIContext = this.getUIContext() as UIContext;
  categoryService: CategoryService = CategoryService.instance;
  segBtnItems: SegmentButtonV2Items = new SegmentButtonV2Items([{ text: '备忘' }, { text: '待办' }]);
  @Provider() kvStore: KVStore | undefined = undefined;
  @Provider('appPathStack') appPathStack: NavPathStack = new NavPathStack();
  @Local isShowSideBar: boolean = false;
  @Local isMultiChoice: boolean = false;
  @Local segBtnIndex: number = 0;
  @Local choiceCount: number = 0;
  @Local searchKeyword: string = '';
  @Local isSearching: boolean = false;
  @Local openSortSheet: boolean = false;
  @Local openCategorySheet: boolean = false;
  @Local sortBy: SortEnum = SortEnum.CREATE_TIME;
  @Local showListType: ShowMethodEnum = ShowMethodEnum.LIST;
  @Local curSystemCategory?: SystemCategory = SystemCategory.ALL_MEMO;
  @Local curUserCategory: UserCategory = this.categoryService.getDefaultCategory();
  @Local sections: WaterFlowSections = new WaterFlowSections();

  @Computed
  get currentMemoList() {
    if (this.curSystemCategory) {
      return this.memoService.getMemosBySystemCategory(this.curSystemCategory);
    } else {
      return this.memoService.getMemosByUserCategory(this.curUserCategory);
    }
  }

  @Computed
  get currentHeader() {
    if (this.curSystemCategory) {
      return this.curSystemCategory;
    } else {
      return this.curUserCategory.name;
    }
  }

  @Computed
  get allMemoCount() {
    return this.memoService.memoList.length;
  }

  @Computed
  get favoriteMemoCount() {
    let count = 0;
    this.memoService.memoList.forEach((memo) => {
      count += memo.isFavorite ? 1 : 0;
    });
    return count;
  }

  @Computed
  get lockedMemoCount() {
    let count = 0;
    this.memoService.memoList.forEach((memo) => {
      count += memo.isLocked ? 1 : 0;
    });
    return count;
  }

  @Computed
  get delMemoCount() {
    return this.memoService.dumpsters.length;
  }

  async aboutToAppear() {
    // 创建KV数据库
    this.kvStore = new KVStore();
    const securityLevel: distributedKVStore.SecurityLevel = distributedKVStore.SecurityLevel.S1;
    this.kvStore.kvStore = await this.kvStore.createKVStore(false, securityLevel, this.uiContext);
    // 加载备忘数据
    await this.memoService.loadEffectiveMemo(this.kvStore);
    await this.memoService.loadDeleteMemo(this.kvStore);
    // 加载分类数据
    await this.categoryService.loadCategoryList(this.kvStore, this.currentMemoList);

    // 设置瀑布流分组信息
    this.sections.push({ itemsCount: 1, crossCount: 1 });
    this.sections.push({ itemsCount: this.currentMemoList.length, crossCount: 2 });
  }

  resetCategory(category: UserCategory) {
    this.curUserCategory = category;
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
    this.onSortConfirm(this.curUserCategory.id, type, '');
  };
  // 列表展开方式
  toggleShowType = (userWaterFlow: ShowMethodEnum) => {
    this.showListType = userWaterFlow;
    this.openSortSheet = false;
  };

  recoverInitState() {
    this.isMultiChoice = false;
    this.choiceCount = 0;
  }

  // 备忘长按事件
  handleLongPress(item: Memo) {
    if (!this.isMultiChoice) {
      this.isMultiChoice = true;
      item.isSelected = true;
      this.choiceCount = 1;
    }
  }

  // 获取选中的笔记
  getChoiceMemo(): Memo[] {
    let choiceMemoArr: Memo[] = [];
    this.currentMemoList.forEach(memo => {
      if (memo.isSelected) {
        choiceMemoArr.push(memo);
      }
    });

    return choiceMemoArr;
  }

  // 全选
  handleChoiceAll() {
    if (this.choiceCount === this.currentMemoList.length) {
      this.currentMemoList.forEach(memo => memo.isSelected = false);
      this.choiceCount = 0;
    } else {
      this.currentMemoList.forEach(memo => memo.isSelected = true);
      this.choiceCount = this.currentMemoList.length;
    }
  }

  // 底部工具栏点击事件 分类、删除、全选
  handleToolBarClick(name: ToolBarName) {
    if (name === ToolBarName.SELECT_ALL) {
      this.handleChoiceAll();
      return;
    }

    const choiceMemoArr = this.getChoiceMemo();
    if (choiceMemoArr.length === 0) {
      try {
        this.getUIContext().getPromptAction().showToast({
          duration: 1500,
          message: '还未选中任何备忘',
          alignment: Alignment.Center,
        });
      } catch (error) {
        console.error(`Failed to showToast. Cause: ${JSON.stringify(error)}`);
      }
      return;
    }

    if (name === ToolBarName.MOVE_CATEGORY) {
      const params: Record<string, Object> =
        {
          'isEditCategory': false,
          'memoList': choiceMemoArr,
          'curUserCategory': this.curUserCategory,
          'resetCategory': () => {
            this.resetCategory(this.curUserCategory);
          }
        };
      this.appPathStack.pushPathByName('CategoryEdit', params);
    } else if (name === ToolBarName.DELETE) {
      choiceMemoArr.forEach((memo) => {
        this.memoService.deleteMemoToTrash(memo.id, memo.categoryId, this.kvStore, this.uiContext);
      });
    }
  }

  @Styles
  headerButtonStyle() {
    .width(40)
    .height(40)
    .padding(8)
    .borderRadius('50%')
    .backgroundColor($r('sys.color.comp_background_list_card'));
  }

  @Builder
  headerArea() {
    Column({ space: 16 }) {
      Row() {
        Image($r('app.media.xmark'))
          .headerButtonStyle()
          .fillColor($r('sys.color.font_primary'))
          .visibility(this.isMultiChoice ? Visibility.Visible : Visibility.Hidden)
          .onClick(() => {
            this.currentMemoList.forEach(memo => memo.isSelected = false);
            this.recoverInitState();
          });

        if (this.isMultiChoice) {
          Text(`已选择${this.choiceCount}项`)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'));
        } else {
          TabSegmentButtonV2({
            items: this.segBtnItems,
            selectedIndex: this.segBtnIndex!!,
            enableStateAnimation: true,
            itemFontSize: LengthMetrics.vp(12),
            itemSelectedFontSize: LengthMetrics.vp(12),
            itemSelectedFontColor: ColorMetrics.numeric(0xEBAC24),
            buttonMinHeight: LengthMetrics.vp(36),
            buttonBackgroundColor: ColorMetrics.resourceColor($r('sys.color.comp_background_list_card')),
          })
            .width(120)
            .height(36);
        }

        Image($r('app.media.more_option'))
          .headerButtonStyle()
          .fillColor($r('sys.color.font_primary'))
          .visibility(this.isMultiChoice ? Visibility.Hidden : Visibility.Visible)
          .onClick(() => {
            this.appPathStack.pushPathByName('MineView', undefined);
          });
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween);

      Column({ space: 5 }) {
        Text(this.currentHeader)
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'));

        if (this.currentMemoList.length > 0) {
          Text(`${this.currentMemoList.length} 条备忘`)
            .fontSize(14)
            .fontWeight(FontWeight.Regular)
            .fontColor($r('sys.color.font_secondary'));
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
    .padding({
      top: 12,
      left: 16,
      right: 16,
      bottom: 12
    });
  }

  @Builder
  searchBar() {
    Search({ placeholder: '搜索' })
      .margin({ bottom: 0 })
      .fontColor($r('sys.color.font_primary'))
      .textFont({ size: $r('sys.float.Body_M') })
      .placeholderColor($r('sys.color.font_secondary'))
      .placeholderFont({ size: $r('sys.float.Body_M') })
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .onSubmit((value: string) => {
        // todo
      })
      .onChange((value: string) => {
        // todo
      });
  }

  @Builder
  editorMemoList() {
    if (!this.isMultiChoice) {
      Row() {
        Row({ space: 4 }) {
          Text(this.curUserCategory.name)
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
  }

  @Builder
  addMemoBuilder() {
    if (
      !this.isMultiChoice &&
        this.curSystemCategory !== SystemCategory.LOCKED_MEMO &&
        this.curSystemCategory !== SystemCategory.DELETE_MEMO
    ) {
      Row() {
        SymbolGlyph($r('sys.symbol.plus'))
          .padding(8)
          .fontSize(35)
          .fontColor([Color.White])
          .borderRadius('50%')
          .backgroundColor('#EBAC24')
          .onClick(() => {
            const params: Record<string, Object> = {
              'memoId': '',
              'userCategory': this.curUserCategory,
              'systemCategory': this.curSystemCategory ?? '',
            };
            this.appPathStack.pushPathByName('MemoEdit', params);
          });
      }
      .width('100%')
      .position({ bottom: 40 })
      .justifyContent(FlexAlign.Center);
    }
  }

  @Builder
  toolBarBuilder() {
    if (this.isMultiChoice) {
      Row() {
        ForEach(
          toolBarList,
          (item: ToolBar) => {
            Column({ space: 5 }) {
              Image(item.icon)
                .width(24)
                .height(24);

              Text(item.name)
                .fontSize(10)
                .fontColor($r('sys.color.font_secondary'));
            }
            .onClick(() => {
              this.handleToolBarClick(item.name);
            });
          },
          (item: ToolBar) => JSON.stringify(item)
        );
      }
      .height(70)
      .width('100%')
      .margin({ top: 10 })
      .padding({ bottom: 10 })
      .justifyContent(FlexAlign.SpaceAround)
      .backgroundColor($r('sys.color.comp_background_list_card'));
    }
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

      if (this.isMultiChoice) {
        Image(item.isSelected ? $r('app.media.selected') : $r('app.media.unselected'))
          .width(35)
          .height(35)
          .padding({ top: 10, right: 10 });
      }
    }
    .onClick(() => {
      if (this.isMultiChoice) {
        item.isSelected = !item.isSelected;
        let choiceCount = 0;
        this.currentMemoList.forEach(memo => choiceCount += memo.isSelected ? 1 : 0);
        this.choiceCount = choiceCount;
      } else {
        const params: Record<string, Object> = { 'memoId': item.id, 'curUserCategory': this.curUserCategory };
        this.appPathStack.pushPathByName('MemoEdit', params);
      }
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
              'curUserCategory': this.curUserCategory,
              'memoList': [memo],
              'resetCategory': () => {
                this.resetCategory(this.curUserCategory);
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
        ListItem() {
          this.searchBar();
        };

        ForEach(
          this.currentMemoList,
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
            })
            .gesture(
              LongPressGesture({ repeat: false, fingers: 1, duration: 500 })
                .onAction(() => {
                  this.handleLongPress(item);
                })
            );
          },
          (item: Memo) => JSON.stringify(item),
        );
      }
      .scrollBar(BarState.Off)
      .contentEndOffset(96);
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
      WaterFlow({ sections: this.sections }) {
        FlowItem() {
          this.searchBar();
        };

        ForEach(
          this.currentMemoList,
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

      Text('没有备忘')
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'));
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center);
  }

  @Builder
  searchNoResult() {
    Column() {
      this.searchBar();

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
    if (this.isSearching && this.currentMemoList.length === 0) {
      this.searchNoResult();
    } else if (!this.isSearching && this.currentMemoList.length === 0) {
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
            (category: UserCategory, index: number) => {
              ListItem() {
                Column() {
                  if (index !== 0) {
                    Divider()
                      .color($r('sys.color.comp_divider'));
                  }

                  Row() {
                    Text(category.name)
                      .fontSize(16)
                      .fontColor(this.curUserCategory.id === category.id ?
                        $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
                      .fontWeight(this.curUserCategory.id === category.id ? FontWeight.Medium : FontWeight.Regular);

                    Blank();

                    Text(String(category.memoCount))
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
            (category: UserCategory) => JSON.stringify(category),
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
        if (this.curUserCategory) {
          const params: Record<string, Object | undefined> =
            { 'isEditCategory': true, 'curUserCategory': this.curUserCategory };
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
  systemCategoryBuilder(icon: Resource, category: SystemCategory, count: Binding<number>) {
    Row() {
      Row({ space: 16 }) {
        Image(icon)
          .width(24)
          .height(24)
          .fillColor($r('sys.color.font_secondary'));

        Text(category)
          .fontSize(13)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'));
      };

      Text(count.value.toString())
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'));
    }
    .padding(8)
    .width('100%')
    .borderRadius(12)
    .justifyContent(FlexAlign.SpaceBetween)
    .backgroundColor(category === this.curSystemCategory ? '#22EBAC24' : Color.Transparent)
    .onClick(() => {
      this.curSystemCategory = category;
      this.getUIContext().animateTo(
        {
          duration: 300,
          curve: Curve.EaseOut,
          playMode: PlayMode.Normal,
        },
        () => {
          this.isShowSideBar = !this.isShowSideBar;
        });
    });
  }

  @Builder
  userCategoryBuilder(category: Binding<UserCategory>) {
    Row() {
      Row({ space: 8 }) {
        Image($r('app.media.folder'))
          .width(24)
          .height(24)
          .fillColor('#EBAC24');

        Text(category.value.name)
          .fontSize(13)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'));
      };

      Text(category.value.memoCount.toString())
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'));
    }
    .padding(8)
    .width('100%')
    .borderRadius(12)
    .justifyContent(FlexAlign.SpaceBetween)
    .backgroundColor(
      !this.curSystemCategory && this.curUserCategory.id === category.value.id ? '#22EBAC24' : Color.Transparent
    )
    .onClick(() => {
      this.curSystemCategory = undefined;
      this.curUserCategory = category.value;
      this.getUIContext().animateTo(
        {
          duration: 300,
          curve: Curve.EaseOut,
          playMode: PlayMode.Normal,
        },
        () => {
          this.isShowSideBar = !this.isShowSideBar;
        });
    });
  }

  @Builder
  sideBarContent() {
    Scroll() {
      Column({ space: 24 }) {
        Column({ space: 12 }) {
          this.systemCategoryBuilder(
            $r('app.media.doc'),
            SystemCategory.ALL_MEMO,
            UIUtils.makeBinding(() => this.allMemoCount)
          );

          this.systemCategoryBuilder(
            $r('app.media.star'),
            SystemCategory.FAVORITE_MEMO,
            UIUtils.makeBinding(() => this.favoriteMemoCount)
          );

          this.systemCategoryBuilder(
            $r('app.media.lock'),
            SystemCategory.LOCKED_MEMO,
            UIUtils.makeBinding(() => this.lockedMemoCount)
          );

          this.systemCategoryBuilder(
            $r('app.media.trash'),
            SystemCategory.DELETE_MEMO,
            UIUtils.makeBinding(() => this.delMemoCount)
          );
        }
        .width('100%');

        Column({ space: 12 }) {
          Row() {
            Text('文件夹')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_secondary'));

            Text('编辑')
              .fontSize(12)
              .fontColor('#EBAC24')
              .fontWeight(FontWeight.Bold);
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .justifyContent(FlexAlign.SpaceBetween);

          ForEach(
            this.categoryService.getCategoryList(),
            (category: UserCategory) => {
              this.userCategoryBuilder(UIUtils.makeBinding(() => category));
            },
            (category: UserCategory) => JSON.stringify(category),
          );

          Row() {
            Text('新建文件夹')
              .fontSize(13)
              .fontColor('#EBAC24')
              .fontWeight(FontWeight.Bold);
          }
          .width('100%')
          .margin({ top: 12 })
          .justifyContent(FlexAlign.Center);
        }
        .width('100%');
      }
      .width('100%')
      .padding({ left: 16, right: 16 });
    }
    .contentEndOffset(48)
    .scrollBar(BarState.Off);
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
      Stack({ alignContent: Alignment.TopStart }) {
        SideBarContainer(SideBarContainerType.Overlay) {
          Column() {
            Column() {
              this.sideBarContent();
            }
            .width('100%')
            .justifyContent(FlexAlign.Start)
            .alignItems(HorizontalAlign.Center)
            .margin({ top: 64 + (AppStorage.get('TopRectHeight') as number) });
          }
          .width('100%')
          .backgroundColor($r('sys.color.background_secondary'));

          Stack() {
            Column() {
              // 顶部栏
              this.headerArea();

              // 工具栏
              this.editorMemoList();

              // 备忘列表
              this.showMemoList();

              // 多选底部工具栏
              this.toolBarBuilder();

              // 新增备忘按钮
              this.addMemoBuilder();
            }
            .width('100%')
            .height('100%')
            .padding({ top: (AppStorage.get('TopRectHeight') as number) });

            if (this.isShowSideBar) {
              Column()
                .width('100%')
                .height('100%')
                .backgroundColor($r('sys.color.ohos_id_color_mask_thin'))
                .onClick(() => {
                  this.getUIContext().animateTo(
                    {
                      duration: 300,
                      curve: Curve.EaseOut,
                      playMode: PlayMode.Normal,
                    },
                    () => {
                      this.isShowSideBar = false;
                    });
                });
            }
          }
          .width('100%')
          .height('100%');
        }
        .width('100%')
        .height('100%')
        .sideBarWidth('80%')
        .showControlButton(false)
        .showSideBar($$this.isShowSideBar);


        if (!this.isMultiChoice) {
          Column() {
            Image(this.isShowSideBar ? $r('app.media.open_sidebar') : $r('app.media.close_sidebar'))
              .headerButtonStyle()
              .fillColor($r('sys.color.font_primary'))
              .onClick(() => {
                this.getUIContext().animateTo(
                  {
                    duration: 300,
                    curve: Curve.EaseOut,
                    playMode: PlayMode.Normal,
                  },
                  () => {
                    this.isShowSideBar = !this.isShowSideBar;
                  });
              });
          }
          .margin({
            top: 12 + (AppStorage.get('TopRectHeight') as number),
            left: 16,
          });
        }
      };
    }
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .backgroundColor($r('sys.color.background_secondary'));
  }
}