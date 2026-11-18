import Decimal from "decimal.js";

// 十進位計算（不使用浮點數）。精度高於 Python 參考實作（28 位），比較時取小數 8 位。
Decimal.set({ precision: 40, rounding: Decimal.ROUND_HALF_EVEN });

export { Decimal };
export type Dec = Decimal;
export const D = (v: Decimal.Value): Decimal => new Decimal(v);
export const ZERO = new Decimal(0);
export const ONE = new Decimal(1);
export const sum = (xs: Decimal[]): Decimal => xs.reduce((a, b) => a.plus(b), ZERO);
