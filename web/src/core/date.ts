// 不含時區的日期以 ISO 字串 "YYYY-MM-DD" 表示（可直接以字串比較大小）。
// 加減天數用 1970-01-01 起算的天數（Howard Hinnant 演算法），與 Swift LocalDate 相同。

export type ISODate = string;

export function daysInMonth(y: number, m: number): number {
  if (m === 2) return (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0 ? 29 : 28;
  return [4, 6, 9, 11].includes(m) ? 30 : 31;
}

export function parts(d: ISODate): [number, number, number] {
  const [y, m, dd] = d.split("-").map(Number);
  return [y, m, dd];
}

export function isValid(d: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(d)) return false;
  const [y, m, dd] = parts(d);
  return m >= 1 && m <= 12 && dd >= 1 && dd <= daysInMonth(y, m);
}

export function make(y: number, m: number, d: number): ISODate {
  return `${String(y).padStart(4, "0")}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

export function toDays(d: ISODate): number {
  const [yy, m, dd] = parts(d);
  const y = m <= 2 ? yy - 1 : yy;
  const era = Math.floor(y / 400);
  const yoe = y - era * 400;
  const mp = (m + 9) % 12;
  const doy = Math.floor((153 * mp + 2) / 5) + dd - 1;
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
  return era * 146097 + doe - 719468;
}

export function fromDays(z0: number): ISODate {
  const z = z0 + 719468;
  const era = Math.floor(z / 146097);
  const doe = z - era * 146097;
  const yoe = Math.floor((doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365);
  const y = yoe + era * 400;
  const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
  const mp = Math.floor((5 * doy + 2) / 153);
  const d = doy - Math.floor((153 * mp + 2) / 5) + 1;
  const m = mp < 10 ? mp + 3 : mp - 9;
  return make(m <= 2 ? y + 1 : y, m, d);
}

export const addDays = (d: ISODate, n: number): ISODate => fromDays(toDays(d) + n);

/** ISO 星期：週一 = 1 … 週日 = 7 */
export function isoWeekday(d: ISODate): number {
  return ((((toDays(d) + 3) % 7) + 7) % 7) + 1;
}

export function isoYearWeek(d: ISODate): [number, number] {
  const thursday = toDays(d) - (isoWeekday(d) - 4);
  const y = parts(fromDays(thursday))[0];
  return [y, Math.floor((thursday - toDays(make(y, 1, 1))) / 7) + 1];
}

export const minDate = (a: ISODate, b: ISODate) => (a < b ? a : b);
export const maxDate = (a: ISODate, b: ISODate) => (a > b ? a : b);

const TZ: Record<string, string> = {
  TW: "Asia/Taipei",
  FUND_TW: "Asia/Taipei",
  US: "America/New_York",
  JP: "Asia/Tokyo",
};

/** 以市場時區判斷「今天」（docs/02 §3.3） */
export function marketToday(market: string, now: Date): ISODate {
  const tz = TZ[market];
  if (!tz) throw new Error(`unknown market ${market}`);
  const f = new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" });
  return f.format(now);
}
