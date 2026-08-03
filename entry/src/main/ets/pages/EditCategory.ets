import { Category, CategoryService, MemoService } from 'data_source';
import { Memo } from 'memo_editor';
import { KVStore } from 'serializer';
import { DialogUtil, StringUtil } from 'utils';
import { ComponentContent } from '@kit.ArkUI';

@Builder
export function EditCategoryBuilder() {
  EditCategory();
}

@ComponentV2
export struct EditCategory {
  private listScroller: ListScroller = new ListScroller();
  private uiContext: UIContext = this.getUIContext() as UIContext;
  private categoryService: CategoryService = CategoryService.instance;
  @Consumer() kvStore: KVStore | undefined = undefined;
  @Local categoryId: string = '';
  @Local isEditCategory: boolean = true;
  @Local isEditCategoryName: boolean = true;
  @Local currentCategory: Category = this.categoryService.getFirstCategory();
  @Local memoList: Memo[] | undefined;

  selectFontColor(item: Category): ResourceStr {
    if (this.isEditCategory) {
      return this.currentCategory.id === item.id ? $r('sys.color.font_primary') : $r('sys.color.font_secondary');
    }
    return this.memoList?.find(memo => memo.categoryId === item.id) ?
      $r('sys.color.font_tertiary') : $r('sys.color.font_secondary');
  }

  selectFontWeight(item: Category): FontWeight {
    if (this.isEditCategory) {
      return this.currentCategory.id === item.id ? FontWeight.Medium : FontWeight.Regular;
    }
    return this.memoList?.find(memo => memo.categoryId === item.id) ? FontWeight.Medium : FontWeight.Regular;
  }

  partOfNoteList(categoryId: string): boolean {
    if (this.memoList) {
      return this.memoList.find(item => item.categoryId === categoryId) ? true : false;
    }
    return false;
  }

  @Builder
  categoryEnd(item: Category) {
    Row() {
      Image($r('app.media.edit_category'))
        .width(40)
        .height(40)
        .margin({ left: 16, right: 16 })
        .onClick(() => {
          this.isEditCategoryName = true;
          this.categoryId = item.id;

          let contentNode: ComponentContent<object> =
            new ComponentContent(this.getUIContext(), wrapBuilder(editCategoryDialog),
              new EditCategoryParam(this.isEditCategoryName, this.categoryService.getCategoryById(this.categoryId),
                this.listScroller, this.kvStore!, this.uiContext));

          DialogUtil.openDialog(this.getUIContext(), contentNode);
        });

      Image($r('app.media.delete_category'))
        .width(40)
        .height(40)
        .onClick(() => {
          this.categoryId = item.id;
          let contentNode: ComponentContent<object> =
            new ComponentContent(this.getUIContext(), wrapBuilder(deleteCategoryDialog),
              new DeleteCategoryParam(this.categoryId, this.listScroller, this.kvStore!, this.uiContext));
          DialogUtil.openDialog(this.getUIContext(), contentNode);
        });
    }
    .width(112)
    .height(48);
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 16 }) {
          List({ space: 12, scroller: this.listScroller }) {
            ForEach(
              this.categoryService.getCategoryList(),
              (item: Category) => {
                ListItem() {
                  Row() {
                    Text(item.name)
                      .fontSize(18)
                      .fontColor(this.selectFontColor(item))
                      .fontWeight(this.selectFontWeight(item));

                    Blank();

                    Text(String(item.totalCount))
                      .fontSize(18)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('sys.color.font_primary'));
                  }
                  .height(48)
                  .width('100%')
                  .borderRadius(18)
                  .padding({ left: '3%', right: '3%' })
                  .backgroundColor(!this.isEditCategory && this.partOfNoteList(item.id) ?
                    $r('sys.color.background_tertiary') : $r('sys.color.comp_background_list_card'));
                }
                .swipeAction({
                  end: {
                    builder: () => {
                      if (item.id !== '-1') {
                        this.categoryEnd(item);
                      }
                    }
                  }
                });
              },
              (item: Category) => JSON.stringify(item),
            );
          };

          Row({ space: 8 }) {
            Image($r('app.media.create_category'))
              .width(24)
              .height(24);
            Text('新建分类')
              .fontSize(18)
              .fontColor($r('sys.color.font_secondary'));
          }
          .height(48)
          .width('100%')
          .borderRadius(16)
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .onClick(() => {
            this.isEditCategoryName = false;
            let contentNode: ComponentContent<object> =
              new ComponentContent(this.getUIContext(), wrapBuilder(editCategoryDialog),
                new EditCategoryParam(this.isEditCategoryName, this.categoryService.getCategoryById(this.categoryId),
                  this.listScroller, this.kvStore!, this.uiContext));
            DialogUtil.openDialog(this.uiContext, contentNode);
          });
        }
        .width('100%')
        .padding({
          top: 10,
          bottom: 50,
          left: $r('sys.float.padding_level8'),
          right: $r('sys.float.padding_level8'),
        });
      }
      .scrollBar(BarState.Off);
    }
    .title('笔记分类')
    .backgroundColor($r('sys.color.background_secondary'))
    .onReady((ctx: NavDestinationContext) => {
      let params = ctx.pathInfo.param as Record<string, Object>;
      this.currentCategory = params.currentCategory as Category;
      this.isEditCategory = params.isEditCategory as boolean;
    });
  }
}

class EditCategoryParam {
  isEdit: boolean;
  category: Category | undefined;
  scroller: ListScroller;
  kvStore: KVStore;
  uiContext: UIContext;

  constructor(isEdit: boolean, category: Category | undefined, scroller: ListScroller, kvStore: KVStore,
    uiContext: UIContext) {
    this.isEdit = isEdit;
    this.category = category;
    this.scroller = scroller;
    this.kvStore = kvStore;
    this.uiContext = uiContext;
  }
}

@Builder
function editCategoryDialog(params: EditCategoryParam) {
  EditCategoryDialog({ params: params });
}

@ComponentV2
struct EditCategoryDialog {
  @Local newName: string = '';
  @Param @Require params: EditCategoryParam;
  private categoryService: CategoryService = CategoryService.instance;

  build() {
    Column() {
      Text(this.params.isEdit ? '重命名' : '新建分类')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .padding({ top: 12, bottom: 12 });

      TextInput({ text: this.params.isEdit ? this.params.category?.name : '' })
        .height(48)
        .fontSize(18)
        .borderRadius(16)
        .fontWeight(FontWeight.Medium)
        .margin({ left: '3%', right: '3%' })
        .onChange((value) => {
          this.newName = value;
        });

      Row() {
        Row() {
          Text('取消')
            .fontSize(16)
            .fontColor('#0A59F7')
            .fontWeight(FontWeight.Medium);
        }
        .height(70)
        .width('50%')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          DialogUtil.closeDialog();
        });

        Row() {
          Text('确定')
            .fontSize(16)
            .fontColor('#0A59F7')
            .fontWeight(FontWeight.Medium);
        }
        .height(70)
        .width('50%')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          if (StringUtil.isBlank(this.newName)) {
            this.getUIContext().getPromptAction().showToast({
              message: '分类名称为空，请重新填写',
              alignment: Alignment.Center,
              duration: 1500,
            });
            return;
          }

          this.params.scroller.closeAllSwipeActions();

          if (this.params.isEdit) {
            if (this.params.category) {
              this.params.category.name = this.newName;
              this.categoryService.updateCategory(this.params.category, this.params.kvStore);
            }
          } else {
            this.categoryService.addCategory(new Category(this.newName, 0), this.params.kvStore, this.params.uiContext);
          }

          DialogUtil.closeDialog();
        });
      };
    }
    .height(158)
    .width('92%')
    .borderRadius(16)
    .backgroundColor($r('sys.color.comp_background_list_card'));
  }
}

class DeleteCategoryParam {
  categoryId: string;
  scroller: ListScroller;
  kvStore: KVStore;
  uiContext: UIContext;

  constructor(categoryId: string, scroller: ListScroller, kvStore: KVStore, uiContext: UIContext) {
    this.categoryId = categoryId;
    this.scroller = scroller;
    this.kvStore = kvStore;
    this.uiContext = uiContext;
  }
}

@Builder
function deleteCategoryDialog(params: DeleteCategoryParam) {
  DeleteCategoryDialog({ params: params });
}

@ComponentV2
struct DeleteCategoryDialog {
  @Param @Require params: DeleteCategoryParam;
  memoService: MemoService = MemoService.instance;
  categoryService: CategoryService = CategoryService.instance;

  build() {
    Column({ space: 30 }) {
      Row() {
        Text('仅删除分类')
          .fontSize(16)
          .onClick(() => {
            this.memoService.moveMemoCategory(this.params.categoryId, this.params.kvStore, this.params.uiContext);
            this.categoryService.deleteCategoryById(this.params.categoryId, this.params.kvStore);

            this.getUIContext().getPromptAction().showToast({
              duration: 1500,
              message: '删除成功',
              alignment: Alignment.Center,
            });
            this.params.scroller.closeAllSwipeActions();
            DialogUtil.closeDialog();
          });
      }
      .height(20)
      .width('100%')
      .justifyContent(FlexAlign.Center);

      Row() {
        Text('删除分类和笔记')
          .fontSize(16)
          .fontColor(Color.Red)
          .onClick(() => {
            // todo
          });
      };
    }
    .width('92%')
    .borderRadius(16)
    .padding({ top: 30, bottom: 30 })
    .backgroundColor($r('sys.color.comp_background_list_card'));
  }
}