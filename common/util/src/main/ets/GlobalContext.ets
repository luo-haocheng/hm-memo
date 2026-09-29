import { common } from '@kit.AbilityKit';


declare namespace globalThis {
  let _brushEngineContext: common.UIAbilityContext;
};

export class GlobalContext {

  static getContext(): common.UIAbilityContext {
    return globalThis._brushEngineContext;
  }

  static setContext(context: common.UIAbilityContext): void {
    globalThis._brushEngineContext = context;
  }
}