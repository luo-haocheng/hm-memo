@ObservedV2
export class Memo {
  id: string = '';
  @Trace title: string = '';
  categoryId: string = '';
  styledString: MutableStyledString;
  serializedStyledString: string;
  createTime: string = '';
  updateTime: string = '';
  @Trace isSelected: boolean = false;
  @Trace  description: string = '';

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