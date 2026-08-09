@ObservedV2
export class Memo {
  @Trace title: string = '';
  @Trace description: string = '';
  @Trace pinTime: string = '-1';
  @Trace isLocked: boolean = false;
  @Trace isFavorite: boolean = false;
  @Trace isSelected: boolean = false;
  id: string = '';
  categoryId: string = '-1';
  createTime: string = '';
  updateTime: string = '';
  styledString: MutableStyledString;
  serializedStyledString: string;

  constructor(styledString: MutableStyledString, title?: string, categoryId?: string) {
    this.styledString = styledString;
    this.serializedStyledString = '';
    this.title = title || '';
    this.categoryId = categoryId || '';
    this.id = new Date().getTime().toString();
    this.createTime = new Date().getTime().toString();
    this.updateTime = this.createTime;
    this.description = this.styledString.getString();
  }

  updateContent(styledString: MutableStyledString, title?: string, category?: string): boolean {
    if (!styledString) {
      return false;
    }
    this.styledString = styledString;
    this.title = title || this.title;
    this.categoryId = category || this.categoryId;
    this.updateTime = new Date().getTime().toString();
    this.description = this.styledString.getString();
    return true;
  }
}