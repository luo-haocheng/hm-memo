import { COMMON_SERVICE, MinePageCommonService } from '../../constants/MineUiConstant';

@Builder
export function MineViewBuilder() {
  MineView();
}

@ComponentV2
export struct MineView {
  @Consumer('appPathStack') appPathStack: NavPathStack = new NavPathStack();

  build() {
    NavDestination() {
      Column() {
        Scroll() {
          Column() {
            // 用户信息模块
            Row() {
              Image($r('app.media.avatar'))
                .width(56)
                .height(56)
                .borderRadius(28)
                .margin({ left: 12 });

              Text('点击登录')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
                .margin({ left: 12 });
            }
            .height(72)
            .width('100%')
            .borderRadius(16)
            .backgroundColor($r('sys.color.comp_background_list_card'));

            List() {
              ForEach(
                COMMON_SERVICE,
                (item: MinePageCommonService) => {
                  MineItem({ commonService: item });
                },
                (item: MinePageCommonService) => item.label,
              );
            }
            .scrollBar(BarState.Off);
          }
          .width('100%');
        }
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring);
      }
      .width('100%')
      .height('100%')
      .padding({
        top: 10,
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
      });
    }
    .title('我的')
    .backgroundColor($r('sys.color.background_secondary'));
  }
}

@ComponentV2
struct MineItem {
  @Consumer('appPathStack') appPathStack: NavPathStack = new NavPathStack();
  @Param @Require commonService: MinePageCommonService;

  build() {
    Row() {
      Image(this.commonService.icon)
        .width(24)
        .height(24)
        .margin({ left: 12 });

      Text(this.commonService.label)
        .fontSize(16)
        .fontColor($r('sys.color.font_primary'))
        .margin({ left: 16 });

      Blank();

      Image($r('app.media.ic_right_arrow_lined'))
        .width(7)
        .height(14)
        .margin({ right: 12 })
        .fillColor($r('sys.color.icon_secondary'));
    }
    .height(46)
    .width('100%')
    .borderRadius(16)
    .margin({ top: 12 })
    .justifyContent(FlexAlign.Start)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .onClick(() => {
      this.appPathStack.pushPathByName(this.commonService.nextPage, undefined);
    });
  }
}