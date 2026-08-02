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
    kvStore.getAll('EffectiveNote')
      .then(async (dataList) => {
        const promises = dataList?.map(async data => {
          const serializedMemo = JSON.parse(data.value as string) as Memo;
          let mss = await SerializeUtil.deserialize(serializedMemo.serializedStyledString);
          const memo = this.constructNote(mss, serializedMemo);
          this.addMemo(memo);
          console.info(`Load memo ${memo.id} success.`);
        }) || [];

        await Promise.all(promises);
        console.info(`Load note data success.`);
      });
  }

  /**
   * 添加笔记
   * @param note
   */
  public async addMemo(note: Memo, kvStore?: KVStore, uiContext?: UIContext) {
    this.memoList.unshift(note);

    if (kvStore && uiContext) {
      putNoteInKvStore(note, uiContext, kvStore, 'EffectiveNote');
    }
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
function putNoteInKvStore(note: Memo, uiContext: UIContext, kvStore: KVStore, prefix: string) {
  SerializeUtil.serialize(note.styledString, uiContext).then(value => {
    let key = prefix + '_' + note.id;
    note.serializedStyledString = value;
    kvStore.put(key, JSON.stringify(note).replace(/__ob_/g, ''));
  });
}