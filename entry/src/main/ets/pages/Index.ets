@Entry
@ComponentV2
struct Index {
  @Provider('appPathStack') appPathStack: NavPathStack = new NavPathStack();

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
  addNoteBuilder() {
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
      this.appPathStack.pushPath({ name: 'NoteEdit' });
    });
  }

  build() {
    Navigation(this.appPathStack) {
      Column() {
        this.headerArea();

        this.searchBar();

        this.addNoteBuilder();
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