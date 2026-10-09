export class DateUtil {
  static isSameDay(date: Date): boolean {
    const now = new Date();
    if (now.getFullYear() !== date.getFullYear()) {
      return false;
    }
    if (now.getMonth() !== date.getMonth()) {
      return false;
    }
    if (now.getDate() !== date.getDate()) {
      return false;
    }
    return true;
  }

  static isSameYear(date: Date): boolean {
    const now = new Date();
    return now.getFullYear() === date.getFullYear();
  }

  static isYesterday(date: Date): boolean {
    const tmpDate = new Date(date);
    tmpDate.setDate(date.getDate() + 1);
    return DateUtil.isSameDay(tmpDate);
  }

  static isSameWeek(date: Date): boolean {
    const now = new Date();
    const todayMs = now.setHours(0, 0, 0, 0);
    const nowDay = now.getDay() === 0 ? 7 : now.getDay();
    const mondayMs = todayMs - (nowDay - 1) * 24 * 60 * 60 * 1000;
    const sundayMs = todayMs + (8 - nowDay) * 24 * 60 * 60 * 1000;

    if (date.getTime() >= mondayMs && date.getTime() < sundayMs) {
      return true;
    }

    return false;
  }

  static isLastWeek(date: Date) {
    const tmpDate = new Date(date);
    tmpDate.setDate(tmpDate.getDate() + 7);
    return DateUtil.isSameWeek(tmpDate);
  }

  static isSameMonth(date: Date): boolean {
    const now = new Date();
    return now.getFullYear() === date.getFullYear() && now.getMonth() === date.getMonth();
  }

  static isLastMonth(date: Date): boolean {
    const tmpDate = new Date(date);
    tmpDate.setMonth(tmpDate.getMonth() + 1);
    return DateUtil.isSameMonth(tmpDate);
  }

  static dateDisplay(dateStr: string): string {
    const date = new Date(parseInt(dateStr));

    const hour = date.getHours();
    const minute = date.getMinutes();
    const hourStr = hour < 10 ? `0${hour}` : `${hour}`;
    const minuteStr = minute < 10 ? `0${minute}` : `${minute}`;
    if (DateUtil.isSameDay(date)) {
      return `今天 ${hourStr}:${minuteStr}`;
    }
    if (DateUtil.isYesterday(date)) {
      return `昨天 ${hourStr}:${minuteStr}`;
    }

    const day = date.getDate();
    const month = date.getMonth() + 1;
    const dayStr = day < 10 ? `0${day}` : `${day}`;
    const monthStr = month < 10 ? `0${month}` : `${month}`;
    if (DateUtil.isSameYear(date)) {
      return `${monthStr}月${dayStr}日`;
    }
    return `${date.getFullYear()}/${monthStr}/${dayStr}`;
  }
}