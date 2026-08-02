/**
 * 用户操作记录，用于undo与redo操作
 */
export class ChangeRecord {
  styledString: MutableStyledString;

  constructor(styledString: MutableStyledString) {
    this.styledString = styledString;
  }
}