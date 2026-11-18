import type { Decimal } from "../core/decimal";

const group = (s: string) => {
  const [i, f] = s.split(".");
  const neg = i.startsWith("-");
  const body = (neg ? i.slice(1) : i).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return (neg ? "-" : "") + body + (f ? "." + f : "");
};

export const digitsFor = (ccy: string) => (ccy === "USD" ? 2 : 0);
export const symbolFor = (ccy: string) => (ccy === "USD" ? "US$" : ccy === "JPY" ? "¥" : "NT$");

export function num(v: Decimal | null | undefined, dp = 2): string {
  return v ? group(v.toFixed(dp)) : "—";
}

export function money(v: Decimal | null | undefined, ccy: string): string {
  if (!v) return "—";
  const s = num(v.abs(), digitsFor(ccy));
  return (v.isNegative() && s.replace(/[0,.]/g, "") !== "" ? "-" : "") + symbolFor(ccy) + s;
}

export function signedMoney(v: Decimal | null | undefined, ccy: string): string {
  return v ? (v.gt(0) ? "+" : "") + money(v, ccy) : "—";
}

export function qty(v: Decimal | null | undefined): string {
  if (!v) return "—";
  return group(v.toDecimalPlaces(6).toString());
}

export function pct(v: Decimal | null | undefined): string {
  if (!v) return "—";
  const p = v.times(100);
  return (p.gt(0) ? "+" : "") + p.toFixed(2) + "%";
}

export const shortDate = (iso: string) => {
  const [y, m, d] = iso.split("-").map(Number);
  return `${y}/${m}/${d}`;
};

export function dateTime(iso?: string | null): string {
  if (!iso) return "—";
  const d = new Date(iso);
  return `${d.getMonth() + 1}/${d.getDate()} ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

export const REASON: Record<string, string> = {
  MONTH_END: "當月無此日，改為月底",
  HOLIDAY_FORWARD: "遇休市順延",
  HOLIDAY_BACKWARD: "遇休市提前",
  MERGED: "與其他期別同一天",
};

export const TX_NAME: Record<string, string> = {
  BUY: "買入", SELL: "賣出", DIVIDEND_CASH: "現金股利", DIVIDEND_STOCK: "股票股利",
  DIVIDEND_REINVEST: "股利再投入", FEE: "費用", SPLIT_ADJUST: "分割調整",
};

/** 本機日期（手機時區）ISO */
export function localToday(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
