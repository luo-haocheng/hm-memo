import IStyleStrategy from './IStyleStrategy';
import { SerializedStyledStringValue } from '../utils/SerializaUtil';
import { LengthMetrics } from '@ohos.arkui.node';

interface SerializedLineHeightStyle extends SerializedStyledStringValue {
  lineHeight: number,
}

export class LineHeightStyleStrategy implements IStyleStrategy<LineHeightStyle, SerializedLineHeightStyle> {
  serialize(value: LineHeightStyle): SerializedLineHeightStyle {
    return {
      lineHeight: value.lineHeight,
    };
  }

  deserialize(data: SerializedLineHeightStyle): LineHeightStyle {
    return new LineHeightStyle(LengthMetrics.vp(data.lineHeight));
  }
}