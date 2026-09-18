/**
 * DateHelper — 真实日历日期工具类
 * 将抽象的"今天/明天/后天"映射为具体日期，让 Agent 计划与真实日历对齐。
 */
export interface WeekDay {
  index: number;         // 0-6, 0 = today
  dateStr: string;       // "2026-07-19"
  monthDay: string;      // "7月19日"
  dayOfWeek: string;     // "周日"
  fullLabel: string;     // "7月19日 周日"
  shortLabel: string;    // "7/19 周日"
  isToday: boolean;
  isWeekend: boolean;
}

const WEEK_DAY_NAMES: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

export class DateHelper {
  /**
   * 获取从今天开始的7天日期列表
   */
  static getWeekDays(): WeekDay[] {
    const today: Date = new Date();
    const result: WeekDay[] = [];

    for (let i: number = 0; i < 7; i++) {
      const date: Date = new Date(today.getFullYear(), today.getMonth(), today.getDate() + i);
      const month: number = date.getMonth() + 1;
      const day: number = date.getDate();
      const dayOfWeekIndex: number = date.getDay();
      const dayOfWeek: string = WEEK_DAY_NAMES[dayOfWeekIndex];
      const isWeekend: boolean = dayOfWeekIndex === 0 || dayOfWeekIndex === 6;
      const dateStr: string = `${date.getFullYear()}-${DateHelper.pad(month)}-${DateHelper.pad(day)}`;

      result.push({
        index: i,
        dateStr: dateStr,
        monthDay: `${month}月${day}日`,
        dayOfWeek: dayOfWeek,
        fullLabel: `${month}月${day}日 ${dayOfWeek}`,
        shortLabel: `${month}/${day} ${dayOfWeek}`,
        isToday: i === 0,
        isWeekend: isWeekend
      });
    }
    return result;
  }

  /**
   * 获取今天的标签（用于匹配任务）
   */
  static getTodayLabel(): string {
    const today: Date = new Date();
    const month: number = today.getMonth() + 1;
    const day: number = today.getDate();
    return `${month}月${day}日`;
  }

  /**
   * 获取今天对应的 dateStr 格式 "YYYY-MM-DD"
   */
  static getTodayDateStr(): string {
    const today: Date = new Date();
    const month: number = today.getMonth() + 1;
    const day: number = today.getDate();
    return `${today.getFullYear()}-${DateHelper.pad(month)}-${DateHelper.pad(day)}`;
  }

  /**
   * 将旧的抽象标签映射到真实日期
   * '今天' → 第0天, '明天' → 第1天, '后天' → 第2天, '周末'/'本周末' → 最近的周末
   */
  static mapLegacyLabel(label: string, weekDays: WeekDay[]): string {
    if (label === '今天') {
      return weekDays[0].fullLabel;
    }
    if (label === '明天') {
      return weekDays[1].fullLabel;
    }
    if (label === '后天') {
      return weekDays[2].fullLabel;
    }
    if (label === '周末' || label === '本周末') {
      // 找到最近的周末（周六或周日）
      for (let i: number = 0; i < weekDays.length; i++) {
        if (weekDays[i].isWeekend && i >= 2) {
          return weekDays[i].fullLabel;
        }
      }
      // 如果没有周末（不太可能），返回最后一天
      return weekDays[6].fullLabel;
    }
    // 如果已经是真实日期格式，直接返回
    return label;
  }

  /**
   * 补零格式化
   */
  static pad(num: number): string {
    return num < 10 ? `0${num}` : `${num}`;
  }

  /**
   * 获取当前是周几的中文名称
   */
  static getTodayDayOfWeek(): string {
    const today: Date = new Date();
    return WEEK_DAY_NAMES[today.getDay()];
  }

  /**
   * 获取本周的日期范围描述（如 "7月13日 - 7月19日"）
   */
  static getWeekRangeLabel(): string {
    const weekDays: WeekDay[] = DateHelper.getWeekDays();
    return `${weekDays[0].monthDay} - ${weekDays[6].monthDay}`;
  }

  /**
   * 根据日期字符串获取周几
   */
  static getDayOfWeekByDate(dateStr: string): string {
    const date: Date = new Date(dateStr);
    if (isNaN(date.getTime())) {
      return '';
    }
    return WEEK_DAY_NAMES[date.getDay()];
  }

  /**
   * 格式化DDL截止日期为可读字符串
   */
  static formatDueDate(dueDateStr: string): string {
    const dueDate: Date = new Date(dueDateStr);
    if (isNaN(dueDate.getTime())) {
      return dueDateStr;
    }
    const month: number = dueDate.getMonth() + 1;
    const day: number = dueDate.getDate();
    const dayOfWeek: string = WEEK_DAY_NAMES[dueDate.getDay()];
    return `${month}月${day}日 ${dayOfWeek}`;
  }

  /**
   * 计算距离截止日期还有多少天
   */
  static calculateDaysLeft(dueDateStr: string): number {
    const today: Date = new Date();
    today.setHours(0, 0, 0, 0);
    const dueDate: Date = new Date(dueDateStr);
    dueDate.setHours(0, 0, 0, 0);
    const diffTime: number = dueDate.getTime() - today.getTime();
    return Math.ceil(diffTime / (1000 * 60 * 60 * 24));
  }
}
