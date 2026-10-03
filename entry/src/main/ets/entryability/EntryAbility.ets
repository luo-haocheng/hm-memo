import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { GlobalContext } from 'util';
import { MemoEditorController } from 'memo_editor';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  initWindow(windowStage: window.WindowStage) {
    try {
      const windowClass: window.Window = windowStage.getMainWindowSync();
      windowClass.setWindowLayoutFullScreen(true)
        .catch((error: BusinessError) => {
          console.error(`Failed to set window layout full screen. Cause: ${JSON.stringify(error)}`);
        });

      const topAvoidArea = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const bottomAvoidArea = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate('TopRectHeight', windowClass.getUIContext().px2vp(topAvoidArea.topRect.height));
      AppStorage.setOrCreate('BottomRectHeight', windowClass.getUIContext().px2vp(bottomAvoidArea.bottomRect.height));

      windowClass.on('avoidAreaChange', (data) => {
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
          AppStorage.setOrCreate('TopRectHeight', windowClass.getUIContext().px2vp(data.area.topRect.height));
        } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          AppStorage.setOrCreate('BottomRectHeight', windowClass.getUIContext().px2vp(data.area.bottomRect.height));
        }
      });
    } catch (error) {
      console.error(`Failed to init window. Cause: ${JSON.stringify(error)}`);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');


    windowStage.loadContent('pages/Index', (err) => {
      this.initWindow(windowStage);
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
    GlobalContext.setContext(this.context);
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    // 退到后台就停录音。
    //
    // 【为什么必须在这里停】录音状态与 AudioCapturer 都挂在进程级单例控制器上。
    // 真机实测：切后台后系统**过一段时间会把这个应用杀掉** —— 与其让麦克风被占着
    // 然后随进程一起消失，不如主动停掉、把释放逻辑走完整。
    //（页面内的 `onWillDisappear` 只管"返回上一页"，不管"退到后台"，所以这里要单独兜）
    MemoEditorController.instance.stopRecord();
  }
};