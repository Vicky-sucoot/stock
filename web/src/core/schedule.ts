// 定期定額期別產生（docs/02 §3）。與 core/python/dca_core/schedule.py 一一對應。
import { addDays, daysInMonth, isoWeekday, isoYearWeek, make, maxDate, minDate, parts, type ISODate } from "./date";

export const MAX_ADJUST_DAYS = 30;
export const LOOKAHEAD_DAYS = 31;

export class TradingCalendar {
  constructor(
    readonly holidays: Set<ISODate> = new Set(),
    readonly knownThrough: ISODate | null = null,
  ) {}

  isOpen(d: ISODate): boolean {
    return isoWeekday(d) < 6 && !this.holidays.has(d);
  }

  isKnown(d: ISODate): boolean {
    return this.knownThrough === null || d <= this.knownThrough;
  }

  private walk(d: ISODate, step: number): ISODate {
    let cur = d;
    for (let i = 0; i <= MAX_ADJUST_DAYS; i++) {
      if (this.isOpen(cur)) return cur;
      cur = addDays(cur, step);
    }
    throw new Error(`no trading day within ${MAX_ADJUST_DAYS} days of ${d}`);
  }

  nextOpen(d: ISODate) {
    return this.walk(d, 1);
  }

  prevOpen(d: ISODate) {
    return this.walk(d, -1);
  }
}

export type Frequency = "WEEKLY" | "MONTHLY" | "DATES";
export type HolidayRule = "NEXT_TRADING_DAY" | "PREV_TRADING_DAY";

export interface Plan {
  frequency: Frequency;
  startDate: ISODate;
  endDate?: ISODate | null;
  weekdays?: number[];
  monthDays?: number[];
  specificDates?: ISODate[];
  holidayRule?: HolidayRule;
  paused?: boolean;
}

export function validatePlan(p: Plan): void {
  if (p.frequency === "WEEKLY" && !p.weekdays?.length) throw new Error("weekly plan needs weekdays");
  if (p.frequency === "MONTHLY" && !p.monthDays?.length) throw new Error("monthly plan needs month_days");
  if (p.frequency === "DATES" && !p.specificDates?.length) throw new Error("dates plan needs specific_dates");
  if ((p.weekdays ?? []).some((w) => !(w >= 1 && w <= 7))) throw new Error("weekday must be 1..7");
  if ((p.monthDays ?? []).some((m) => !(m >= 1 && m <= 31))) throw new Error("month day must be 1..31");
  if (p.endDate && p.endDate < p.startDate) throw new Error("end before start");
}

export interface Occurrence {
  periodKey: string;
  nominalDate: ISODate;
  scheduledDate: ISODate;
  adjustReasons: string[];
  mergedKeys: string[];
  calendarUnknown: boolean;
}

function nominal(p: Plan, lo: ISODate, hi: ISODate): [string, ISODate, string[]][] {
  const out: [string, ISODate, string[]][] = [];
  if (lo > hi) return out;
  if (p.frequency === "WEEKLY") {
    const wanted = new Set(p.weekdays);
    for (let d = lo; d <= hi; d = addDays(d, 1)) {
      const wd = isoWeekday(d);
      if (wanted.has(wd)) {
        const [iy, iw] = isoYearWeek(d);
        out.push([`${iy}-W${String(iw).padStart(2, "0")}#${wd}`, d, []]);
      }
    }
  } else if (p.frequency === "MONTHLY") {
    const days = [...new Set(p.monthDays)].sort((a, b) => a - b);
    let [y, m] = parts(lo);
    const [hy, hm] = parts(hi);
    while (y < hy || (y === hy && m <= hm)) {
      const dim = daysInMonth(y, m);
      for (const md of days) {
        const nd = make(y, m, Math.min(md, dim));
        if (lo <= nd && nd <= hi) out.push([`${y}-${String(m).padStart(2, "0")}#${md}`, nd, md > dim ? ["MONTH_END"] : []]);
      }
      m += 1;
      if (m === 13) {
        y += 1;
        m = 1;
      }
    }
  } else {
    for (const sd of [...new Set(p.specificDates)].sort()) {
      if (lo <= sd && sd <= hi) out.push([`D${sd}`, sd, []]);
    }
  }
  return out;
}

function schedule(p: Plan, cal: TradingCalendar, lo: ISODate, hi: ISODate): Occurrence[] {
  const occs: Occurrence[] = nominal(p, lo, hi).map(([key, nd, base]) => {
    const reasons = [...base];
    let sd: ISODate;
    if (cal.isOpen(nd)) sd = nd;
    else if ((p.holidayRule ?? "NEXT_TRADING_DAY") === "NEXT_TRADING_DAY") {
      sd = cal.nextOpen(nd);
      reasons.push("HOLIDAY_FORWARD");
    } else {
      sd = cal.prevOpen(nd);
      reasons.push("HOLIDAY_BACKWARD");
    }
    return { periodKey: key, nominalDate: nd, scheduledDate: sd, adjustReasons: reasons, mergedKeys: [], calendarUnknown: !cal.isKnown(sd) };
  });
  const byDay = new Map<ISODate, string[]>();
  for (const o of occs) byDay.set(o.scheduledDate, [...(byDay.get(o.scheduledDate) ?? []), o.periodKey]);
  for (const o of occs) {
    const keys = byDay.get(o.scheduledDate)!;
    if (keys.length > 1) {
      o.adjustReasons.push("MERGED");
      o.mergedKeys = keys.filter((k) => k !== o.periodKey);
    }
  }
  const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
  return occs.sort((a, b) => cmp(a.scheduledDate, b.scheduledDate) || cmp(a.nominalDate, b.nominalDate) || cmp(a.periodKey, b.periodKey));
}

/** 應產生為「待確認」的期別：scheduledDate <= today 且尚未存在。 */
export function dueOccurrences(p: Plan, cal: TradingCalendar, today: ISODate, existingKeys: Set<string> = new Set(), since?: ISODate | null): Occurrence[] {
  validatePlan(p);
  if (p.paused) return [];
  const lo = since ? maxDate(p.startDate, since) : p.startDate;
  let hi = addDays(today, LOOKAHEAD_DAYS);
  if (p.endDate) hi = minDate(hi, p.endDate);
  return schedule(p, cal, lo, hi).filter((o) => o.scheduledDate <= today && !existingKeys.has(o.periodKey));
}

/** 編輯畫面的「接下來 n 期」預覽。 */
export function upcomingOccurrences(p: Plan, cal: TradingCalendar, today: ISODate, count: number): Occurrence[] {
  validatePlan(p);
  if (p.paused || count <= 0) return [];
  const lo = maxDate(p.startDate, addDays(today, -LOOKAHEAD_DAYS));
  let span = 400;
  for (;;) {
    let hi = addDays(today, span);
    if (p.endDate) hi = minDate(hi, p.endDate);
    const out = schedule(p, cal, lo, hi).filter((o) => o.scheduledDate > today);
    if (out.length >= count || (p.endDate && hi >= p.endDate) || span > 3700) return out.slice(0, count);
    span *= 2;
  }
}
