import { Memo } from 'memo_editor';
import { KVStore } from 'serializer';
import {
  CategoryService,
  MemoService,
  SettingService,
  SettingStore,
  ShowMethodEnum,
  SortMethodEnum,
  SystemCategory,
  UserCategory
} from 'data_source';
import { distributedKVStore } from '@kit.ArkData';
import {
  CATEGORY_COLOR_LIST,
  DeleteToolBarList,
  NormalToolBarList,
  SegBtnItems,
  ToolBar,
  ToolBarName
} from '../constants/HomeUIConstant';
import { Binding, ColorMetrics, LengthMetrics, TabSegmentButtonV2, UIUtils } from '@kit.ArkUI';

@Entry
@ComponentV2
struct Index {
  memoService: MemoService = MemoService.instance;
  settingService: SettingService = SettingService.instance;
  categoryService: CategoryService = CategoryService.instance;
  moveToCategoryDialogId: number = 0;
  createEditCategoryDialogId: number = 0;
  cardScroller: Scroller = new Scroller();
  cardListScroller: ListScroller = new ListScroller();
  uiContext: UIContext = this.getUIContext() as UIContext;
  @Provider() kvStore: KVStore | undefined = undefined;
  @Provider() settingStore: SettingStore | undefined = undefined;
  @Provider('appPathStack') appPathStack: NavPathStack = new NavPathStack();
  @Local segBtnIndex: number = 0;
  @Local isMultiChoice: boolean = false;
  @Local isShowSideBar: boolean = false;
  @Local newCategoryName: string = '';
  @Local newCategoryColor: ResourceColor = '#EBAC24';
  @Local isEditCategory: boolean = false;
  @Local isCardListScroll: boolean = false;
  @Local duplicateCategoryName: boolean = false;
  @Local moveMemoList: Array<Memo> = [];
  @Local isMoveToNewCategory: boolean = false;
  @Local selectSortMethod: boolean = false;
  @Local isSearching: boolean = false;
  @Local searchKeyWord: string = '';
  @Local curEditCategory?: UserCategory = undefined;
  @Local curSystemCategory?: SystemCategory = SystemCategory.ALL_MEMO;
  @Local curUserCategory: UserCategory = this.categoryService.getDefaultCategory();

  @Computed
  get currentMemoList() {
    let memoList: Array<Memo> = [];
    if (this.curSystemCategory) {
      memoList = this.memoService.getMemosBySystemCategory(this.curSystemCategory);
    } else {
      memoList = this.memoService.getMemosByUserCategory(this.curUserCategory);
    }
    if (this.settingService.memoSortMethod === SortMethodEnum.CREATE_TIME) {
      memoList.sort((a, b) => {
        if (a.pinTime !== b.pinTime) {
          return parseInt(b.pinTime) - parseInt(a.pinTime);
        }
        return parseInt(b.createTime) - parseInt(a.createTime);
      });
    } else {
      memoList.sort((a, b) => {
        if (a.pinTime !== b.pinTime) {
          return parseInt(b.pinTime) - parseInt(a.pinTime);
        }
        return parseInt(b.updateTime) - parseInt(a.updateTime);
      });
    }

    return memoList;
  }

  get groupedMemoList(): Map<string, Memo[]> {
    const groupedMemo: Map<string, Memo[]> = new Map([]);
    this.currentMemoList.forEach((memo) => {
      const dateStr = this.settingService.memoSortMethod === SortMethodEnum.CREATE_TIME ?
        memo.createTime : memo.updateTime;
      const date = new Date(parseInt(dateStr));
      let matchedKey = '更久之前';
      if (memo.pinTime !== '-1') {
        matchedKey = '置顶';
      } else if (isSameDay(date)) {
        matchedKey = '今天';
      } else if (isYesterday(date)) {
        matchedKey = '昨天';
      } else if (isSameWeek(date)) {
        matchedKey = '本周';
      } else if (isLastWeek(date)) {
        matchedKey = '上周';
      } else if (isSameMonth(date)) {
        matchedKey = '本月';
      } else if (isLastMonth(date)) {
        matchedKey = '上月';
      } else {
        matchedKey = '更久之前';
      }
      const memoList = groupedMemo.get(matchedKey);
      if (!memoList) {
        groupedMemo.set(matchedKey, [memo]);
      } else {
        memoList.push(memo);
      }
    });

    return groupedMemo;
  }

  get searchMemoList(): Memo[] {
    if (this.isSearching && this.searchKeyWord) {
      const lowerKeyword = this.searchKeyWord.toLowerCase();

      return this.currentMemoList.filter((memo) => {
        return memo.title.toLowerCase().includes(lowerKeyword) || memo.description.toLowerCase().includes(lowerKeyword);
      });
    }

    return this.currentMemoList;
  }

  @Computed
  get allMemoCount() {
    return this.memoService.memoList.length;
  }

  @Computed
  get choiceMemoCount() {
    let count = 0;
    this.currentMemoList.forEach((memo) => {
      count += memo.isSelected ? 1 : 0;
    });
    return count;
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
    const securityLevel = distributedKVStore.SecurityLevel.S1;
    this.kvStore.kvStore = await this.kvStore.createKVStore(false, securityLevel, this.uiContext);
    // 创建Preference数据库
    this.settingStore = new SettingStore();
    this.settingStore.createPreference(this.uiContext);
    // 加载用户设置
    await this.settingService.loadUserSetting(this.settingStore);
    // 加载备忘数据
    await this.memoService.loadEffectiveMemo(this.kvStore);
    await this.memoService.loadDeleteMemo(this.kvStore);
    // 加载分类数据
    await this.categoryService.loadCategoryList(this.kvStore, this.currentMemoList);
  }

  onBackPress(): boolean | void {
    if (this.isMultiChoice) {
      this.getUIContext().animateTo(
        {
          duration: 300,
          curve: Curve.Ease,
          playMode: PlayMode.Normal,
        },
        () => {
          this.isMultiChoice = false;
        });
      return true;
    } else if (this.isShowSideBar) {
      this.getUIContext().animateTo(
        {
          duration: 300,
          curve: Curve.Ease,
          playMode: PlayMode.Normal,
        },
        () => {
          this.isShowSideBar = false;
        });
      return true;
    } else if (this.isSearching) {
      this.getUIContext().animateTo(
        {
          duration: 300,
          curve: Curve.Ease,
          playMode: PlayMode.Normal,
        },
        () => {
          this.isSearching = false;
        });
      return true;
    }

    return false;
  }

  currentHeader() {
    if (this.curSystemCategory) {
      return this.curSystemCategory;
    } else {
      return this.curUserCategory.name;
    }
  }

  // 备忘长按事件
  handleLongPress(item: Memo) {
    if (!this.isMultiChoice) {
      this.currentMemoList.forEach(memo => memo.isSelected = false);
      this.isMultiChoice = true;
      item.isSelected = true;
    }
  }

  // 全选
  handleChoiceAll() {
    if (this.choiceMemoCount === this.currentMemoList.length) {
      this.currentMemoList.forEach(memo => memo.isSelected = false);
    } else {
      this.currentMemoList.forEach(memo => memo.isSelected = true);
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

  // 底部工具栏点击事件 分类、删除、全选
  handleToolBarClick(name: ToolBarName) {
    if (name === ToolBarName.SELECT_ALL) {
      this.handleChoiceAll();
      return;
    }

    const choiceMemos = this.getChoiceMemo();
    if (choiceMemos.length === 0) {
      return;
    }

    if (name === ToolBarName.MOVE) {
      this.moveMemoList = choiceMemos;
      this.isMoveToNewCategory = false;
      this.newCategoryName = '';
      this.newCategoryColor = '#EBAC24';
      this.duplicateCategoryName = false;
      this.uiContext.getPromptAction()
        .openCustomDialog({
          builder: () => {
            this.moveToCategoryDialog();
          },
          width: '100%',
          alignment: DialogAlignment.Bottom,
          transition: TransitionEffect.SLIDE,
          keyboardAvoidMode: KeyboardAvoidMode.NONE,
          offset: { dx: 0, dy: AppStorage.get('BottomRectHeight') as number },
        })
        .then((dialogId: number) => {
          this.moveToCategoryDialogId = dialogId;
        })
        .catch((error: BusinessError) => {
          console.error(`Failed to openCustomDialog. Cause: ${JSON.stringify(error)}`);
        });

      try {
        this.cardListScroller.closeAllSwipeActions();
      } catch (error) {
        console.error(`Failed to invoke closeAllSwipeActions. Cause: ${JSON.stringify(error)}`);
      }
    } else if (name === ToolBarName.DELETE) {
      choiceMemos.forEach((memo) => {
        if (this.curSystemCategory === SystemCategory.DELETE_MEMO) {
          this.memoService.deletePermanently(memo.id, this.kvStore);
        } else {
          this.memoService.deleteMemoToTrash(memo.id, memo.categoryId, this.kvStore, this.uiContext);
        }
      });
    } else if (name === ToolBarName.RECOVER) {
      choiceMemos.forEach((memo) => {
        this.memoService.recoverMemo(memo.id, this.kvStore, this.uiContext);
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
            this.isMultiChoice = false;
          });

        if (this.isMultiChoice) {
          Text(this.choiceMemoCount === 0 ? '未选择' : `已选择${this.choiceMemoCount}项`)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'));
        } else {
          TabSegmentButtonV2({
            items: SegBtnItems,
            selectedIndex: this.segBtnIndex!!,
            itemFontSize: LengthMetrics.vp(12),
            itemSelectedFontSize: LengthMetrics.vp(12),
            itemSelectedFontColor: ColorMetrics.numeric(0xEBAC24),
            buttonMinHeight: LengthMetrics.vp(36),
            buttonBackgroundColor: ColorMetrics.resourceColor($r('sys.color.comp_background_list_card')),
            enableStateAnimation: true,
          })
            .width(120)
            .height(36);
        }

        Image($r('app.media.more_option'))
          .headerButtonStyle()
          .fillColor($r('sys.color.font_primary'))
          .visibility(this.isMultiChoice ? Visibility.Hidden : Visibility.Visible)
          .bindMenu(this.moreOptionsMenu, {
            onWillDisappear: () => {
              this.selectSortMethod = false;
            }
          });
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween);

      if (!this.isMultiChoice) {
        Column({ space: 5 }) {
          Text(this.currentHeader())
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'));

          if (this.currentMemoList.length > 0 && !this.isCardListScroll) {
            Text(`${this.currentMemoList.length} 条备忘`)
              .fontSize(14)
              .fontWeight(FontWeight.Regular)
              .fontColor($r('sys.color.font_secondary'));
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start);
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
    .padding({
      top: 12,
      left: 16,
      right: 16,
      bottom: 12,
    });
  }

  @Builder
  moreOptionsMenu() {
    Column() {
      if (this.currentMemoList.length > 0) {
        Row() {
          Text('多选')
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'));
        }
        .width('100%')
        .padding({ top: 16, bottom: 16 })
        .borderWidth({ bottom: 0.5 })
        .borderColor($r('sys.color.ohos_id_color_button_divider'))
        .onClick(() => {
          this.isMultiChoice = true;
        });
      }

      Row() {
        Text(this.settingService.memoShowMethod === ShowMethodEnum.LIST ? ShowMethodEnum.Grid : ShowMethodEnum.LIST)
          .fontSize(14)
          .fontColor($r('sys.color.font_primary'));
      }
      .width('100%')
      .padding({ top: 16, bottom: 16 })
      .borderWidth({ bottom: 0.5 })
      .borderColor($r('sys.color.ohos_id_color_button_divider'))
      .onClick(() => {
        if (this.settingService.memoShowMethod === ShowMethodEnum.LIST) {
          this.settingService.setMemoShowMethod(this.settingStore!, ShowMethodEnum.Grid);
        } else {
          this.settingService.setMemoShowMethod(this.settingStore!, ShowMethodEnum.LIST);
        }
      });

      Row() {
        Text('排序方式')
          .fontSize(14)
          .fontColor(Color.Black);

        Image($r('app.media.chevron_down'))
          .width(20)
          .height(20)
          .backgroundColor(Color.Transparent)
          .rotate({ angle: this.selectSortMethod ? 180 : 0 });
      }
      .width('100%')
      .padding({ top: 16, bottom: 16 })
      .borderWidth({ bottom: 0.5 })
      .borderColor($r('sys.color.ohos_id_color_button_divider'))
      .justifyContent(FlexAlign.SpaceBetween)
      .onClick(() => {
        this.getUIContext().animateTo(
          {
            duration: 300,
            curve: Curve.Ease,
            playMode: PlayMode.Normal,
          },
          () => {
            this.selectSortMethod = !this.selectSortMethod;
          });
      })
      .onTouch((event: TouchEvent) => {
        event.stopPropagation();
      });

      if (this.selectSortMethod) {
        Row() {
          Text('创建时间')
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1);

          if (this.settingService.memoSortMethod === SortMethodEnum.CREATE_TIME) {
            Image($r('app.media.checkmark'))
              .width(20)
              .height(20)
              .backgroundColor(Color.Transparent)
              .layoutWeight(0);
          }
        }
        .margin({ left: 16 })
        .padding({ top: 16, bottom: 16 })
        .borderWidth({ bottom: 0.5 })
        .borderColor($r('sys.color.ohos_id_color_button_divider'))
        .justifyContent(FlexAlign.SpaceBetween)
        .onClick(() => {
          this.settingService.setMemoSortMethod(this.settingStore!, SortMethodEnum.CREATE_TIME);
        });

        Row() {
          Text('编辑时间')
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1);

          if (this.settingService.memoSortMethod === SortMethodEnum.UPDATE_TIME) {
            Image($r('app.media.checkmark'))
              .width(20)
              .height(20)
              .backgroundColor(Color.Transparent)
              .layoutWeight(0);
          }
        }
        .margin({ left: 16 })
        .padding({ top: 16, bottom: 16 })
        .borderWidth({ bottom: 0.5 })
        .borderColor($r('sys.color.ohos_id_color_button_divider'))
        .justifyContent(FlexAlign.SpaceBetween)
        .onClick(() => {
          this.settingService.setMemoSortMethod(this.settingStore!, SortMethodEnum.UPDATE_TIME);
        });
      }

      Row() {
        Text(this.settingService.isGroupByDate ? '取消按日期分组' : '按日期分组')
          .fontSize(14)
          .fontColor($r('sys.color.font_primary'));
      }
      .width('100%')
      .padding({ top: 16, bottom: 16 })
      .onClick(() => {
        this.settingService.setIsGroupByDate(this.settingStore!, !this.settingService.isGroupByDate);
      });
    }
    .width(200)
    .padding({ left: 8, right: 8 })
    .backgroundColor($r('sys.color.menu_back_blur_color'));
  }

  @Builder
  searchBar() {
    if (!this.isMultiChoice) {
      Row({ space: 8 }) {
        if (this.isSearching) {
          Image($r('app.media.chevron_left'))
            .width(40)
            .height(40)
            .padding(12)
            .borderRadius('50%')
            .fillColor($r('sys.color.font_primary'))
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .layoutWeight(0)
            .onClick(() => {
              this.getUIContext().animateTo(
                {
                  duration: 300,
                  curve: Curve.Ease,
                  playMode: PlayMode.Normal,
                },
                () => {
                  this.isSearching = false;
                  this.searchKeyWord = '';
                  this.getUIContext().getFocusController().clearFocus();
                });
            });
        }

        Search({ value: this.searchKeyWord!!, placeholder: '搜索' })
          .margin({ bottom: 0 })
          .searchIcon({ size: 14 })
          .fontColor($r('sys.color.font_primary'))
          .textFont({ size: $r('sys.float.Body_M') })
          .placeholderColor($r('sys.color.font_secondary'))
          .placeholderFont({ size: $r('sys.float.Body_M') })
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .layoutWeight(1)
          .onFocus(() => {
            this.getUIContext().animateTo(
              {
                duration: 300,
                curve: Curve.Ease,
                playMode: PlayMode.Normal,
              },
              () => {
                this.isSearching = true;
              });
          });
      }
      .width('100%')
      .margin({ top: 8, bottom: 12 });
    }
  }

  isAddMemoButtonShow = () => {
    if (this.isMultiChoice) {
      return false;
    }
    if (this.isSearching) {
      return false;
    }
    if (this.isShowSideBar) {
      return false;
    }
    if (this.curSystemCategory === SystemCategory.LOCKED_MEMO) {
      return false;
    }
    if (this.curSystemCategory === SystemCategory.DELETE_MEMO) {
      return false;
    }
    return true;
  };

  @Builder
  addMemoButton() {
    if (this.isAddMemoButtonShow()) {
      SymbolGlyph($r('sys.symbol.plus'))
        .padding(10)
        .fontSize(32)
        .fontColor([Color.White])
        .borderRadius('50%')
        .backgroundColor('#EBAC24')
        .translate({ x: '-50%' })
        .position({ bottom: AppStorage.get('BottomRectHeight') as number, left: '50%' })
        .onClick(() => {
          const params: Record<string, Object> = {
            'memoId': '',
            'userCategory': this.curUserCategory,
            'systemCategory': this.curSystemCategory ?? '',
          };
          this.appPathStack.pushPathByName('MemoEdit', params);
        });
    }
  }

  currentToolBar = () => {
    return this.curSystemCategory === SystemCategory.DELETE_MEMO ? DeleteToolBarList : NormalToolBarList;
  };
  isDeselectAll = (name: ToolBarName) => {
    return name === ToolBarName.SELECT_ALL && this.choiceMemoCount === this.currentMemoList.length;
  };
  isToolBarEnable = (name: ToolBarName) => {
    return name === ToolBarName.SELECT_ALL || this.choiceMemoCount > 0;
  };

  @Builder
  toolBarBuilder() {
    if (this.isMultiChoice) {
      Row({ space: 24 }) {
        ForEach(
          this.currentToolBar(),
          (item: ToolBar) => {
            Button({ stateEffect: false }) {
              Column({ space: 5 }) {
                Image(item.icon)
                  .width(24)
                  .height(24)
                  .fillColor(this.isDeselectAll(item.name) ? '#EBAC24' : $r('sys.color.font_primary'));

                Text(this.isDeselectAll(item.name) ? '取消全选' : item.name)
                  .fontSize(10)
                  .fontWeight(600)
                  .fontColor(this.isDeselectAll(item.name) ? '#EBAC24' : $r('sys.color.font_primary'));
              }
              .width('100%');
            }
            .width(40)
            .backgroundColor(Color.Transparent)
            .enabled(this.isToolBarEnable(item.name))
            .onClick(() => {
              this.handleToolBarClick(item.name);
            });
          },
          (item: ToolBar) => JSON.stringify(item)
        );
      }
      .borderRadius('50%')
      .padding({
        top: 8,
        bottom: 8,
        left: 24,
        right: 24
      })
      .backgroundColor($r('sys.color.segment_button_v2_capsule_button_background'))
      .translate({ x: '-50%' })
      .position({ left: '50%', bottom: AppStorage.get('BottomRectHeight') as number });
    }
  }

  memoColor(memo: Memo): ResourceColor {
    const category = this.categoryService.getCategoryById(memo.categoryId);
    if (!category) {
      return '#EBAC24';
    } else {
      return category.color;
    }
  }

  @Builder
  cardItem(memo: Binding<Memo>) {
    Row() {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Column()
            .width(3)
            .height(14)
            .borderRadius(3)
            .backgroundColor(this.memoColor(memo.value))
            .layoutWeight(0);

          Text(memo.value.title)
            .maxLines(1)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1);
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(VerticalAlign.Center);

        Row({ space: 5 }) {
          Text(
            dateDisplay(this.settingService.memoSortMethod === SortMethodEnum.CREATE_TIME ?
              memo.value.createTime :
              memo.value.updateTime
            ))
            .fontSize(12)
            .fontWeight(FontWeight.Regular)
            .fontColor($r('sys.color.font_secondary'))
            .layoutWeight(0);

          Row({ space: 5 }) {
            if (memo.value.isLocked) {
              Image($r('app.media.lock_fill'))
                .width(12)
                .height(12)
                .fillColor($r('sys.color.font_secondary'));
            }

            if (memo.value.pinTime !== '-1') {
              Image($r('app.media.pin_to_top'))
                .width(12)
                .height(12)
                .fillColor($r('sys.color.font_secondary'));
            }

            if (memo.value.isFavorite) {
              Image($r('app.media.star_fill'))
                .width(12)
                .height(12)
                .fillColor($r('sys.color.font_secondary'));
            }
          }
          .layoutWeight(0);

          Text(memo.value.description)
            .maxLines(1)
            .fontSize(12)
            .fontWeight(FontWeight.Regular)
            .fontColor($r('sys.color.font_secondary'))
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1);
        }
        .margin({ left: 12 })
        .justifyContent(FlexAlign.Start)
        .alignItems(VerticalAlign.Center);
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      if (this.isMultiChoice) {
        Checkbox()
          .width(20)
          .height(20)
          .selectedColor('#EBAC24')
          .select(memo.value.isSelected!!);
      }
    }
    .padding(16)
    .width('100%')
    .borderRadius(16)
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.SpaceBetween)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .onClick(() => {
      if (this.isMultiChoice) {
        memo.value.isSelected = !memo.value.isSelected;
      } else {
        const params: Record<string, Object> = { 'memoId': memo.value.id, 'curUserCategory': this.curUserCategory };
        this.appPathStack.pushPathByName('MemoEdit', params);
      }
    });
  }

  @Builder
  memoItemEnd(memo: Memo) {
    Row({ space: 8 }) {
      // 置顶/取消置顶
      Image(memo.pinTime === '-1' ? $r('app.media.pin_to_top') : $r('app.media.unpin_to_top'))
        .width(40)
        .height(40)
        .padding(8)
        .borderRadius('50%')
        .fillColor(Color.White)
        .backgroundColor('#3CB371')
        .onClick(() => {
          let pinTime = '-1';
          if (memo.pinTime === '-1') {
            pinTime = new Date().getTime().toString();
          }

          this.getUIContext().animateTo(
            {
              duration: 300,
              curve: Curve.Ease,
              playMode: PlayMode.Normal,
            },
            () => {
              this.memoService.pinMemo(memo.id, pinTime, this.kvStore, this.uiContext);
            });

          try {
            this.cardListScroller.closeAllSwipeActions();
          } catch (error) {
            console.error(`Failed to invoke closeAllSwipeActions. Cause: ${JSON.stringify(error)}`);
          }
        });

      // 移动备忘
      Image($r('app.media.arrow_right_folder_fill'))
        .width(40)
        .height(40)
        .padding(8)
        .borderRadius('50%')
        .fillColor(Color.White)
        .backgroundColor('#3498DB')
        .onClick(() => {
          this.moveMemoList = [memo];
          this.newCategoryName = '';
          this.newCategoryColor = '#EBAC24';
          this.isMoveToNewCategory = false;
          this.duplicateCategoryName = false;
          this.uiContext.getPromptAction()
            .openCustomDialog({
              builder: () => {
                this.moveToCategoryDialog();
              },
              width: '100%',
              alignment: DialogAlignment.Bottom,
              transition: TransitionEffect.SLIDE,
              keyboardAvoidMode: KeyboardAvoidMode.NONE,
              offset: { dx: 0, dy: AppStorage.get('BottomRectHeight') as number },
            })
            .then((dialogId: number) => {
              this.moveToCategoryDialogId = dialogId;
            })
            .catch((error: BusinessError) => {
              console.error(`Failed to openCustomDialog. Cause: ${JSON.stringify(error)}`);
            });

          try {
            this.cardListScroller.closeAllSwipeActions();
          } catch (error) {
            console.error(`Failed to invoke closeAllSwipeActions. Cause: ${JSON.stringify(error)}`);
          }
        });

      // 收藏/取消收藏
      Image(memo.isFavorite ? $r('app.media.star_fill') : $r('app.media.star'))
        .width(40)
        .height(40)
        .padding(8)
        .borderRadius('50%')
        .fillColor(Color.White)
        .backgroundColor('#F1C40F')
        .onClick(() => {
          memo.isFavorite = !memo.isFavorite;
          this.memoService.collectMemo(memo.id, memo.isFavorite, this.kvStore, this.uiContext);

          try {
            this.cardListScroller.closeAllSwipeActions();
          } catch (error) {
            console.error(`Failed to invoke closeAllSwipeActions. Cause: ${JSON.stringify(error)}`);
          }
        });

      // 删除备忘到回收站
      Image($r('app.media.trash_fill'))
        .width(40)
        .height(40)
        .padding(8)
        .borderRadius('50%')
        .fillColor(Color.White)
        .backgroundColor(Color.Red)
        .onClick(() => {
          this.getUIContext().animateTo(
            {
              duration: 300,
              curve: Curve.Ease,
              playMode: PlayMode.Normal,
            },
            () => {
              this.memoService.deleteMemoToTrash(memo.id, memo.categoryId, this.kvStore, this.uiContext);
            });
        });
    }
    .alignItems(VerticalAlign.Center)
    .padding($r('sys.float.padding_level8'));
  }

  @Builder
  deleteMemoEnd(memo: Memo) {
    Row({ space: 8 }) {
      // 恢复按钮
      Image($r('app.media.arrow_counterclockwise'))
        .width(40)
        .height(40)
        .padding(8)
        .borderRadius('50%')
        .fillColor(Color.White)
        .backgroundColor('#3498DB')
        .onClick(() => {
          this.getUIContext().animateTo(
            {
              duration: 300,
              curve: Curve.Ease,
              playMode: PlayMode.Normal,
            },
            () => {
              this.memoService.recoverMemo(memo.id, this.kvStore, this.uiContext);
            });
        });

      // 删除按钮
      Image($r('app.media.trash'))
        .width(40)
        .height(40)
        .padding(8)
        .borderRadius('50%')
        .fillColor(Color.White)
        .backgroundColor(Color.Red)
        .onClick(() => {
          this.getUIContext().animateTo(
            {
              duration: 300,
              curve: Curve.Ease,
              playMode: PlayMode.Normal,
            },
            () => {
              this.memoService.deletePermanently(memo.id, this.kvStore);
            });
        });
    }
    .alignItems(VerticalAlign.Center)
    .padding($r('sys.float.padding_level8'));
  }

  @Builder
  groupHeader(key: string) {
    Row() {
      Text(key)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'));
    }
    .width('100%')
    .margin({ bottom: 8 })
    .justifyContent(FlexAlign.Start)
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  memoGroupList() {
    Scroll(this.cardScroller) {
      Column() {
        Row() {
          this.searchBar();
        }
        .width('100%')
        .layoutWeight(0);

        if (this.isSearching && this.searchKeyWord) {
          if (this.searchMemoList.length > 0) {
            Row() {
              Text('备忘')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('sys.color.font_primary'));

              Text(`已找到 ${this.searchMemoList.length} 项`)
                .fontSize(12)
                .fontColor($r('sys.color.font_tertiary'));
            }
            .width('100%')
            .margin({ bottom: 12 })
            .alignItems(VerticalAlign.Center)
            .justifyContent(FlexAlign.SpaceBetween);

            List({ space: 12, scroller: this.cardListScroller }) {
              ForEach(
                this.searchMemoList,
                (memo: Memo) => {
                  ListItem() {
                    this.cardItem(UIUtils.makeBinding(() => memo));
                  }
                  .swipeAction({
                    end: {
                      builder: () => {
                        if (!this.isMultiChoice) {
                          if (this.curSystemCategory === SystemCategory.DELETE_MEMO) {
                            this.deleteMemoEnd(memo);
                          } else {
                            this.memoItemEnd(memo);
                          }
                        }
                      }
                    }
                  });
                },
                (item: Memo) => JSON.stringify(item),
              );
            }
            .width('100%')
            .contentEndOffset(96)
            .scrollBar(BarState.Off)
            .layoutWeight(this.isSearching ? 1 : 0);
          } else {
            Column({ space: 16 }) {
              Image($r('app.media.search_no_result'))
                .width(120)
                .height(120)
                .fillColor($r('sys.color.font_tertiary'));

              Text('没有符合条件的内容')
                .fontSize(12)
                .fontColor($r('sys.color.font_tertiary'));
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .layoutWeight(1);
          }
        } else {
          List({ space: 12, scroller: this.cardListScroller }) {
            ForEach(
              Array.from(this.groupedMemoList.keys()),
              (key: string) => {
                if (this.groupedMemoList.get(key) && this.groupedMemoList.get(key)!.length > 0) {
                  ListItemGroup({ header: this.groupHeader(key), space: 12 }) {
                    ForEach(
                      this.groupedMemoList.get(key),
                      (memo: Memo) => {
                        ListItem() {
                          this.cardItem(UIUtils.makeBinding(() => memo));
                        }
                        .swipeAction({
                          end: {
                            builder: () => {
                              if (!this.isMultiChoice) {
                                if (this.curSystemCategory === SystemCategory.DELETE_MEMO) {
                                  this.deleteMemoEnd(memo);
                                } else {
                                  this.memoItemEnd(memo);
                                }
                              }
                            }
                          }
                        })
                        .gesture(
                          LongPressGesture({ repeat: false, fingers: 1, duration: 500 })
                            .onAction(() => {
                              this.handleLongPress(memo);
                            })
                        );
                      },
                      (memo: Memo) => JSON.stringify(memo),
                    );
                  };
                }
              },
              (key: string) => key,
            );
          }
          .width('100%')
          .contentEndOffset(96)
          .scrollBar(BarState.Off)
          .layoutWeight(this.isSearching ? 1 : 0);
        }
      }
      .width('100%')
      .padding({
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
      });
    }
    .width('100%')
    .layoutWeight(1)
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .onDidScroll(() => {
      const yOffset = this.cardScroller.currentOffset().yOffset;
      if (yOffset > 32 && !this.isCardListScroll) {
        this.getUIContext().animateTo(
          {
            duration: 300,
            curve: Curve.EaseOut,
            playMode: PlayMode.Normal,
          },
          () => {
            this.isCardListScroll = true;
          });
      }
    })
    .onScrollEdge((side: Edge) => {
      if (side === Edge.Top && this.isCardListScroll) {
        this.getUIContext().animateTo(
          {
            duration: 300,
            curve: Curve.EaseOut,
            playMode: PlayMode.Normal,
          },
          () => {
            this.isCardListScroll = false;
          });
      }
    });
  }

  @Builder
  memoList() {
    Scroll(this.cardScroller) {
      Column() {
        Row() {
          this.searchBar();
        }
        .width('100%')
        .layoutWeight(0);

        if (this.isSearching && this.searchKeyWord) {
          if (this.searchMemoList.length > 0) {
            Row() {
              Text('备忘')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('sys.color.font_primary'));

              Text(`已找到 ${this.searchMemoList.length} 项`)
                .fontSize(12)
                .fontColor($r('sys.color.font_tertiary'));
            }
            .width('100%')
            .margin({ bottom: 12 })
            .alignItems(VerticalAlign.Center)
            .justifyContent(FlexAlign.SpaceBetween);

            List({ space: 12, scroller: this.cardListScroller }) {
              ForEach(
                this.searchMemoList,
                (memo: Memo) => {
                  ListItem() {
                    this.cardItem(UIUtils.makeBinding(() => memo));
                  }
                  .swipeAction({
                    end: {
                      builder: () => {
                        if (!this.isMultiChoice) {
                          if (this.curSystemCategory === SystemCategory.DELETE_MEMO) {
                            this.deleteMemoEnd(memo);
                          } else {
                            this.memoItemEnd(memo);
                          }
                        }
                      }
                    }
                  });
                },
                (item: Memo) => JSON.stringify(item),
              );
            }
            .width('100%')
            .contentEndOffset(96)
            .scrollBar(BarState.Off)
            .layoutWeight(this.isSearching ? 1 : 0);
          } else {
            Column({ space: 16 }) {
              Image($r('app.media.search_no_result'))
                .width(120)
                .height(120)
                .fillColor($r('sys.color.font_tertiary'));

              Text('没有符合条件的内容')
                .fontSize(12)
                .fontColor($r('sys.color.font_tertiary'));
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .layoutWeight(1);
          }
        } else {
          List({ space: 12, scroller: this.cardListScroller }) {
            ForEach(
              this.currentMemoList,
              (memo: Memo) => {
                ListItem() {
                  this.cardItem(UIUtils.makeBinding(() => memo));
                }
                .swipeAction({
                  end: {
                    builder: () => {
                      if (!this.isMultiChoice) {
                        if (this.curSystemCategory === SystemCategory.DELETE_MEMO) {
                          this.deleteMemoEnd(memo);
                        } else {
                          this.memoItemEnd(memo);
                        }
                      }
                    }
                  }
                })
                .gesture(
                  LongPressGesture({ repeat: false, fingers: 1, duration: 500 })
                    .onAction(() => {
                      this.handleLongPress(memo);
                    })
                );
              },
              (item: Memo) => JSON.stringify(item),
            );
          }
          .width('100%')
          .contentEndOffset(96)
          .scrollBar(BarState.Off)
          .layoutWeight(this.isSearching ? 1 : 0);
        }
      }
      .width('100%')
      .padding({
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
      });
    }
    .width('100%')
    .layoutWeight(1)
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .onDidScroll(() => {
      const yOffset = this.cardScroller.currentOffset().yOffset;
      if (yOffset > 32 && !this.isCardListScroll) {
        this.getUIContext().animateTo(
          {
            duration: 300,
            curve: Curve.EaseOut,
            playMode: PlayMode.Normal,
          },
          () => {
            this.isCardListScroll = true;
          });
      }
    })
    .onScrollEdge((side: Edge) => {
      if (side === Edge.Top && this.isCardListScroll) {
        this.getUIContext().animateTo(
          {
            duration: 300,
            curve: Curve.EaseOut,
            playMode: PlayMode.Normal,
          },
          () => {
            this.isCardListScroll = false;
          });
      }
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
  showMemoList() {
    if (this.currentMemoList.length === 0) {
      this.emptyMemos();
    } else {
      if (this.settingService.isGroupByDate) {
        this.memoGroupList();
      } else {
        this.memoList();
      }
    }
  }

  @Builder
  ColorPickerItem(color: ResourceColor) {
    Column() {
      if (this.newCategoryColor === color) {
        Column()
          .width(14)
          .aspectRatio(1)
          .borderRadius('50%')
          .backgroundColor($r('sys.color.background_primary'));
      }
    }
    .width(this.newCategoryColor === color ? 28 : 24)
    .aspectRatio(1)
    .borderRadius('50%')
    .backgroundColor(color)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.newCategoryColor = color;
    });
  }

  @Builder
  CategoryColorPicker1() {
    Row() {
      ForEach(
        CATEGORY_COLOR_LIST,
        (color: ResourceStr) => {
          this.ColorPickerItem(color);
        },
        (color: ResourceStr) => JSON.stringify(color),
      );
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween);
  }

  @Builder
  CategoryColorPicker2() {
    Column({ space: 12 }) {
      Row() {
        ForEach(
          CATEGORY_COLOR_LIST.slice(0, CATEGORY_COLOR_LIST.length / 2),
          (color: ResourceStr) => {
            this.ColorPickerItem(color);
          },
          (color: ResourceStr) => JSON.stringify(color),
        );
      }
      .width('50%')
      .justifyContent(FlexAlign.SpaceBetween);

      Row() {
        ForEach(
          CATEGORY_COLOR_LIST.slice(CATEGORY_COLOR_LIST.length / 2),
          (color: ResourceStr) => {
            this.ColorPickerItem(color);
          },
          (color: ResourceStr) => JSON.stringify(color),
        );
      }
      .width('50%')
      .justifyContent(FlexAlign.SpaceBetween);
    }
    .padding(12);
  }

  @Builder
  createEditCategoryDialog() {
    Column() {
      Row() {
        Text(this.isEditCategory ? '编辑文件夹' : '新建文件夹')
          .fontSize(16)
          .fontWeight(FontWeight.Bold);
      }
      .width('100%')
      .margin({ bottom: 18 })
      .justifyContent(FlexAlign.Center);

      this.CategoryColorPicker1();

      Row() {
        Image($r('app.media.folder'))
          .width(24)
          .height(24)
          .fillColor(this.newCategoryColor)
          .layoutWeight(0);

        TextInput({
          placeholder: '新建文件夹',
          text: $$this.newCategoryName,
        })
          .fontSize(13)
          .maxLength(100)
          .placeholderFont({ size: 13 })
          .padding({ left: 8, right: 8 })
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .onDidInsert(() => {
            this.duplicateCategoryName = false;
          });

      }
      .width('100%')
      .borderRadius('50%')
      .margin({ top: 18 })
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('sys.color.textfield_bg_color'));

      if (this.duplicateCategoryName) {
        Text('文件夹分类名称已存在')
          .fontSize(10)
          .fontColor(Color.Red)
          .margin({ top: 8 });
      }

      Row() {
        Button({ type: ButtonType.Capsule, stateEffect: false }) {
          Text('取消')
            .fontSize(14)
            .fontColor('#EBAC24');
        }
        .padding(8)
        .width('50%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          try {
            this.uiContext.getPromptAction().closeCustomDialog(this.createEditCategoryDialogId);
          } catch (error) {
            console.error(`Failed to closeCustomeDialog. Cause: ${JSON.stringify(error)}`);
          }
        });

        Divider()
          .height(24)
          .vertical(true)
          .strokeWidth(1)
          .color($r('sys.color.ohos_id_divider_color'));

        Button({ type: ButtonType.Capsule, stateEffect: false }) {
          Text('保存')
            .fontSize(14)
            .fontColor('#EBAC24')
            .opacity(this.newCategoryName ? 1 : 0.3);
        }
        .padding(8)
        .width('50%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          if (!this.newCategoryName) {
            return;
          }

          if (this.categoryService.isDuplicateCategory(this.newCategoryName)) {
            if (!this.isEditCategory || this.curEditCategory?.name !== this.newCategoryName) {
              this.newCategoryName = '';
              this.duplicateCategoryName = true;
              return;
            }
          }

          if (this.isEditCategory) {
            if (this.curEditCategory && this.kvStore) {
              this.curEditCategory.name = this.newCategoryName;
              this.curEditCategory.color = this.newCategoryColor;
              this.categoryService.updateCategory(this.curEditCategory, this.kvStore);
              if (this.curEditCategory.id === this.curUserCategory.id) {
                this.curUserCategory.name = this.curEditCategory.name;
              }
            }
          } else {
            const newCategory = new UserCategory(this.newCategoryName, this.newCategoryColor, 0);
            this.categoryService.addCategory(newCategory, this.kvStore!, this.uiContext);
          }

          try {
            this.uiContext.getPromptAction().closeCustomDialog(this.createEditCategoryDialogId);
          } catch (error) {
            console.error(`Failed to closeCustomeDialog. Cause: ${JSON.stringify(error)}`);
          }
        });
      }
      .width('100%')
      .margin({ top: 18 })
      .justifyContent(FlexAlign.SpaceBetween);
    }
    .padding({
      top: 16,
      left: 24,
      right: 25,
      bottom: 16
    });
  }

  @Builder
  moveCategoryItem(category: Binding<UserCategory>) {
    Column() {
      Button() {
        Row() {
          Row({ space: 8 }) {
            Image($r('app.media.folder'))
              .width(24)
              .height(24)
              .fillColor(category.value.color);

            Text(category.value.name)
              .fontSize(13)
              .fontWeight(600)
              .fontColor($r('sys.color.font_primary'));
          };

          if (!this.moveMemoList.some(memo => memo.categoryId !== category.value.id)) {
            Checkbox()
              .width(18)
              .height(18)
              .select(true)
              .selectedColor('#EBAC24')
              .hitTestBehavior(HitTestMode.None);
          }
        }
        .width('100%')
        .borderRadius(12)
        .padding({ left: 8, right: 8 })
        .justifyContent(FlexAlign.SpaceBetween);
      }
      .padding({ top: 12, bottom: 12 })
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        // 移动目录
        this.moveMemoList
          .filter((memo) => memo.categoryId !== category.value.id)
          .forEach((memo) => {
            this.getUIContext().animateTo(
              {
                duration: 300,
                curve: Curve.EaseOut,
                playMode: PlayMode.Normal,
              },
              () => {
                this.categoryService.moveCategory(memo, category.value.id);

                memo.categoryId = category.value.id;
                this.memoService.updateMemo(memo, this.kvStore, this.uiContext);
              });
          });
        // 关闭弹窗
        try {
          this.uiContext.getPromptAction().closeCustomDialog(this.moveToCategoryDialogId);
        } catch (error) {
          console.error(`Failed to closeCustomeDialog. Cause: ${JSON.stringify(error)}`);
        }
      });

      Divider()
        .width('100%')
        .strokeWidth(1)
        .margin({ left: 32 })
        .color($r('sys.color.ohos_id_divider_color'));
    }
    .width('100%');
  }

  @Builder
  moveToCategoryDialog() {
    Column({ space: 12 }) {
      Row() {
        Text('选择文件夹')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'));

        Image($r('app.media.xmark'))
          .width(40)
          .height(40)
          .padding(10)
          .borderRadius('50%')
          .fillColor($r('sys.color.font_primary'))
          .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
          .onClick(() => {
            // 关闭弹窗
            try {
              this.uiContext.getPromptAction().closeCustomDialog(this.moveToCategoryDialogId);
            } catch (error) {
              console.error(`Failed to closeCustomeDialog. Cause: ${JSON.stringify(error)}`);
            }
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.SpaceBetween);

      Scroll() {
        Column() {
          ForEach(
            this.categoryService.getCategoryList(),
            (category: UserCategory) => {
              ListItem() {
                this.moveCategoryItem(UIUtils.makeBinding(() => category));
              };
            },
            (category: UserCategory) => JSON.stringify(category),
          );

          if (!this.isMoveToNewCategory) {
            Row() {
              Text('新建文件夹')
                .fontSize(13)
                .fontColor('#EBAC24')
                .fontWeight(FontWeight.Bold)
                .onClick(() => {
                  this.isMoveToNewCategory = true;
                });
            }
            .width('100%')
            .margin({ top: 24 })
            .justifyContent(FlexAlign.Center);
          } else {
            Column() {
              Row() {
                Image($r('app.media.xmark'))
                  .width(40)
                  .height(40)
                  .padding(10)
                  .borderRadius('50%')
                  .fillColor($r('sys.color.font_primary'))
                  .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
                  .layoutWeight(0)
                  .onClick(() => {
                    this.isMoveToNewCategory = false;
                  });

                Row() {
                  Image($r('app.media.folder'))
                    .width(24)
                    .height(24)
                    .fillColor(this.newCategoryColor)
                    .layoutWeight(0)
                    .bindMenu(this.CategoryColorPicker2, {
                      placement: Placement.Top,
                    });

                  TextInput({
                    placeholder: '名称',
                    text: $$this.newCategoryName,
                  })
                    .padding(8)
                    .fontSize(14)
                    .maxLength(100)
                    .showUnderline(true)
                    .underlineColor(Color.Gray)
                    .placeholderFont({ size: 14 })
                    .backgroundColor(Color.Transparent)
                    .layoutWeight(1)
                    .onDidInsert(() => {
                      this.duplicateCategoryName = false;
                    });

                }
                .margin({ left: 8, right: 8 })
                .layoutWeight(1);


                Image($r('app.media.checkmark'))
                  .width(40)
                  .height(40)
                  .padding(10)
                  .borderRadius('50%')
                  .opacity(this.newCategoryName ? 1 : 0.3)
                  .fillColor($r('sys.color.font_primary'))
                  .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
                  .layoutWeight(0)
                  .onClick(() => {
                    if (!this.newCategoryName) {
                      return;
                    }
                    // 分类名称是否重复
                    if (this.categoryService.isDuplicateCategory(this.newCategoryName)) {
                      this.newCategoryName = '';
                      this.duplicateCategoryName = true;
                      return;
                    }
                    // 新建分类
                    const newCategory = new UserCategory(this.newCategoryName, this.newCategoryColor, 0);
                    this.categoryService.addCategory(newCategory, this.kvStore!, this.uiContext);
                    // 移动到新建分类
                    this.moveMemoList
                      .forEach((memo) => {
                        this.categoryService.moveCategory(memo, newCategory.id);

                        memo.categoryId = newCategory.id;
                        this.memoService.updateMemo(memo, this.kvStore, this.uiContext);
                      });
                    // 关闭弹窗
                    try {
                      this.uiContext.getPromptAction().closeCustomDialog(this.moveToCategoryDialogId);
                    } catch (error) {
                      console.error(`Failed to closeCustomeDialog. Cause: ${JSON.stringify(error)}`);
                    }
                  });
              }
              .width('100%')
              .margin({ top: 24 })
              .justifyContent(FlexAlign.SpaceBetween);

              if (this.duplicateCategoryName) {
                Text('文件夹分类名称已存在')
                  .fontSize(10)
                  .fontColor(Color.Red)
                  .margin({ top: 8 });
              }
            }
            .alignItems(HorizontalAlign.Center);
          }
        }
        .width('100%');
      }
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off);
    }
    .padding(16)
    .width('100%')
    .height('100%');
  }

  @Builder
  systemCategoryItem(icon: Resource, category: SystemCategory, count: Binding<number>) {
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
  userCategoryItem(category: Binding<UserCategory>) {
    Row() {
      Row({ space: 8 }) {
        Image($r('app.media.folder'))
          .width(24)
          .height(24)
          .fillColor(category.value.color);

        Text(category.value.name)
          .fontSize(13)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
          .opacity((this.isEditCategory && category.value.id === '-1') ? 0.3 : 1);
      };

      if (!this.isEditCategory) {
        Text(category.value.memoCount.toString())
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'));
      } else if (category.value.id !== '-1') {
        Row({ space: 16 }) {
          // 删除按钮
          Image($r('app.media.trash'))
            .width(24)
            .height(24)
            .fillColor(Color.Gray)
            .onClick(() => {
              this.memoService.updateMemoCategory(category.value.id, this.kvStore!, this.uiContext);
              this.categoryService.deleteCategoryById(category.value.id, this.kvStore!);
              if (category.value.id === this.curUserCategory.id) {
                this.curUserCategory = this.categoryService.getDefaultCategory();
              }
            });

          // 编辑按钮
          Image($r('app.media.square_and_pencil'))
            .width(24)
            .height(24)
            .fillColor(Color.Gray)
            .onClick(() => {
              this.duplicateCategoryName = false;
              this.curEditCategory = category.value;
              this.newCategoryName = category.value.name;
              this.newCategoryColor = category.value.color;
              this.uiContext.getPromptAction()
                .openCustomDialog({
                  builder: () => {
                    this.createEditCategoryDialog();
                  },
                  width: '90%',
                  autoCancel: false,
                  alignment: DialogAlignment.Center,
                  transition: TransitionEffect.SLIDE,
                })
                .then((dialogId: number) => {
                  this.createEditCategoryDialogId = dialogId;
                })
                .catch((error: BusinessError) => {
                  console.error(`Failed to openCustomDialog. Cause: ${JSON.stringify(error)}`);
                });
            });
        }
        .alignItems(VerticalAlign.Center);
      }
    }
    .padding(8)
    .width('100%')
    .borderRadius(12)
    .justifyContent(FlexAlign.SpaceBetween)
    .backgroundColor(
      !this.curSystemCategory && this.curUserCategory.id === category.value.id ? '#22EBAC24' : Color.Transparent
    )
    .onClick(() => {
      if (this.isEditCategory) {
        return;
      }

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
          this.systemCategoryItem(
            $r('app.media.doc'),
            SystemCategory.ALL_MEMO,
            UIUtils.makeBinding(() => this.allMemoCount)
          );

          this.systemCategoryItem(
            $r('app.media.star'),
            SystemCategory.FAVORITE_MEMO,
            UIUtils.makeBinding(() => this.favoriteMemoCount)
          );

          this.systemCategoryItem(
            $r('app.media.lock'),
            SystemCategory.LOCKED_MEMO,
            UIUtils.makeBinding(() => this.lockedMemoCount)
          );

          this.systemCategoryItem(
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

            Text(this.isEditCategory ? '取消' : '编辑')
              .fontSize(12)
              .fontColor('#EBAC24')
              .fontWeight(FontWeight.Bold)
              .onClick(() => {
                this.isEditCategory = !this.isEditCategory;
                this.curEditCategory = undefined;
              });
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .justifyContent(FlexAlign.SpaceBetween);

          ForEach(
            this.categoryService.getCategoryList(),
            (category: UserCategory) => {
              this.userCategoryItem(UIUtils.makeBinding(() => category));
            },
            (category: UserCategory) => JSON.stringify(category),
          );

          Row() {
            Text('新建文件夹')
              .fontSize(13)
              .fontColor('#EBAC24')
              .fontWeight(FontWeight.Bold)
              .opacity(this.isEditCategory ? 0.3 : 1);
          }
          .width('100%')
          .margin({ top: 12 })
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            if (this.isEditCategory) {
              return;
            }
            this.newCategoryName = '';
            this.newCategoryColor = '#EBAC24';
            this.duplicateCategoryName = false;
            this.uiContext.getPromptAction()
              .openCustomDialog({
                builder: () => {
                  this.createEditCategoryDialog();
                },
                width: '90%',
                autoCancel: false,
                alignment: DialogAlignment.Center,
                transition: TransitionEffect.SLIDE,
              })
              .then((dialogId: number) => {
                this.createEditCategoryDialogId = dialogId;
              })
              .catch((error: BusinessError) => {
                console.error(`Failed to openCustomDialog. Cause: ${JSON.stringify(error)}`);
              });
          });
        }
        .width('100%');
      }
      .width('100%')
      .padding({ left: 16, right: 16 });
    }
    .padding({ bottom: 48 })
    .scrollBar(BarState.Off);
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
              if (!this.isSearching) {
                this.headerArea();
              }

              // 备忘列表
              this.showMemoList();

              // 多选底部工具栏
              this.toolBarBuilder();

              // 新增备忘按钮
              this.addMemoButton();
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


        if (!this.isMultiChoice && !this.isSearching) {
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

function isSameDay(date: Date): boolean {
  const now = new Date();
  if (now.getFullYear() !== date.getFullYear()) {
    return false;
  }
  if (now.getMonth() !== date.getMonth()) {
    return false;
  }
  if (now.getDate() !== date.getDate()) {
    return false;
  }
  return true;
}

function isSameYear(date: Date): boolean {
  const now = new Date();
  return now.getFullYear() === date.getFullYear();
}

function isYesterday(date: Date): boolean {
  const tmpDate = new Date(date);
  tmpDate.setDate(date.getDate() + 1);
  return isSameDay(tmpDate);
}

function isSameWeek(date: Date): boolean {
  const now = new Date();
  const todayMs = now.setHours(0, 0, 0, 0);
  const nowDay = now.getDay() === 0 ? 7 : now.getDay();
  const mondayMs = todayMs - (nowDay - 1) * 24 * 60 * 60 * 1000;
  const sundayMs = todayMs + (8 - nowDay) * 24 * 60 * 60 * 1000;

  if (date.getTime() >= mondayMs && date.getTime() < sundayMs) {
    return true;
  }

  return false;
}

function isLastWeek(date: Date) {
  const tmpDate = new Date(date);
  tmpDate.setDate(tmpDate.getDate() + 7);
  return isSameWeek(tmpDate);
}

function isSameMonth(date: Date): boolean {
  const now = new Date();
  return now.getFullYear() === date.getFullYear() && now.getMonth() === date.getMonth();
}

function isLastMonth(date: Date): boolean {
  const tmpDate = new Date(date);
  tmpDate.setMonth(tmpDate.getMonth() + 1);
  return isSameMonth(tmpDate);
}

function dateDisplay(dateStr: string): string {
  const date = new Date(parseInt(dateStr));
  if (isSameDay(date)) {
    return `今天 ${date.getHours()}:${date.getMinutes()}`;
  }
  if (isYesterday(date)) {
    return `昨天 ${date.getHours()}:${date.getMinutes()}`;
  }
  if (isSameYear(date)) {
    return `${date.getMonth() + 1}月${date.getDate()}日`;
  }

  return `${date.getFullYear()}/${date.getMonth() + 1}/${date.getDate()}`;
}
