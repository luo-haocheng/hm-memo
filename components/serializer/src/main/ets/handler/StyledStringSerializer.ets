import IStyleStrategy from '../strategy/IStyleStrategy';
import { TextStyleStrategy } from '../strategy/TextStyleStrategy';
import { DecorationStyleStrategy } from '../strategy/DecorationStyleStrategy';
import { ParagraphStyleStrategy } from '../strategy/ParagraphStyleStrategy';
import { SerializedStyledStringValue } from '../utils/SerializaUtil';
import { LineHeightStyleStrategy } from '../strategy/LineHeightStyleStretegy';

export class StyledStringSerializer {
  private static strategies: Map<StyledStringKey, IStyleStrategy<StyledStringValue, object>> = new Map();
  static {
    StyledStringSerializer.register(StyledStringKey.FONT, new TextStyleStrategy());
    StyledStringSerializer.register(StyledStringKey.DECORATION, new DecorationStyleStrategy());
    StyledStringSerializer.register(StyledStringKey.LINE_HEIGHT, new LineHeightStyleStrategy());
    StyledStringSerializer.register(StyledStringKey.PARAGRAPH_STYLE, new ParagraphStyleStrategy());
  }

  /**
   * 注册新的策略（用于扩展）
   */
  private static register(key: StyledStringKey, strategy: IStyleStrategy<StyledStringValue, object>) {
    StyledStringSerializer.strategies.set(key, strategy);
  }

  /**
   * 序列化
   */
  public static serialize(key: StyledStringKey, style: StyledStringValue): SerializedStyledStringValue {
    const strategy = StyledStringSerializer.strategies.get(key);
    if (!strategy) {
      console.error(`No strategy found for styled key: ${key}`);
      throw new Error(`No strategy found for styled key: ${key}`);
    }
    return strategy.serialize(style);
  }

  /**
   * 反序列化
   */
  public static deserialize(value: SerializedStyledStringValue, styledKey: StyledStringKey): StyledStringValue {
    const strategy = StyledStringSerializer.strategies.get(styledKey);
    if (!strategy) {
      throw new Error(`No strategy found for styled key: ${styledKey}`);
    }

    switch (styledKey) {
      case StyledStringKey.FONT:
        return strategy.deserialize(value) as TextStyle;
      case StyledStringKey.DECORATION:
        return strategy.deserialize(value) as DecorationStyle;
      case StyledStringKey.LINE_HEIGHT:
        return strategy.deserialize(value) as LineHeightStyle;
      case StyledStringKey.PARAGRAPH_STYLE:
        return strategy.deserialize(value) as ParagraphStyle;
      default:
        throw new Error(`Not support for styled key: ${styledKey}`);
    }
  }
}