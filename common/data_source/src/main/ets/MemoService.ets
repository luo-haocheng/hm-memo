import { Memo } from 'memo_editor';
import { KVStore, SerializeUtil } from 'serializer';

@ObservedV2
export class MemoService {
  private static _instance: MemoService;

  public static get instance() {
    if (!MemoService._instance) {
      MemoService._instance = new MemoService();
    }
    return MemoService._instance;
  }

  @Trace private memoList: Memo[] = [];

  public async loadEffectiveNote(kvStore: KVStore) {
    const dataList = await kvStore.getAll('EffectiveNote');
    if (!dataList) {
      return;
    }
    for (let i = 0; i < dataList.length; i++) {
      const serializedMemo = JSON.parse(dataList[i].value as string) as Memo;
      let mss = await SerializeUtil.deserialize(serializedMemo.serializedStyledString);
      const memo = this.constructNote(mss, serializedMemo);
      await this.addMemo(memo);
      console.info(`Load memo ${memo.id} success.`);
    }
    console.info(`Load note data success.`);
  }

  /**
   * 添加笔记
   * @param note
   */
  public async addMemo(note: Memo, kvStore?: KVStore, uiContext?: UIContext) {
    this.memoList.unshift(note);

    if (kvStore && uiContext) {
      await putNoteInKvStore(note, uiContext, kvStore, 'EffectiveNote');
    }
  }

  /**
   * 更新笔记
   */
  public updateNote(note: Memo, kvStore?: KVStore, uiContext?: UIContext) {
    const index = this.memoList.findIndex((item) => item.id === note.id);
    this.memoList.splice(index, 1, note);

    if (kvStore && uiContext) {
      putNoteInKvStore(note, uiContext, kvStore, 'EffectiveNote');
    }
  }

  /**
   * 根据Id获取笔记
   */
  public getNoteById(id: string): Memo | undefined {
    if (id === '') {
      return undefined;
    }
    return this.memoList.find((item) => item.id === id);
  }

  /**
   * 查询笔记列表
   */
  public getNoteList() {
    this.memoList.sort((a, b) => parseInt(b.createTime) - parseInt(a.createTime));
    return this.memoList;
  }

  private constructNote(value: MutableStyledString, serializedNote: Memo) {
    const note = new Memo(value);
    note.id = serializedNote.id;
    note.title = serializedNote.title;
    note.categoryId = serializedNote.categoryId;
    note.createTime = serializedNote.createTime;
    note.updateTime = serializedNote.updateTime;
    note.description = serializedNote.description;
    return note;
  }
}

/**
 * 持久化 保存笔记
 * @param note
 * @param uiContext
 * @param kvStore
 * @param prefix
 */
async function putNoteInKvStore(note: Memo, uiContext: UIContext, kvStore: KVStore, prefix: string) {
  const data = await SerializeUtil.serialize(note.styledString, uiContext);
  let key = prefix + '_' + note.id;
  note.serializedStyledString = data;
  kvStore.put(key, JSON.stringify(note).replace(/__ob_/g, ''));
}