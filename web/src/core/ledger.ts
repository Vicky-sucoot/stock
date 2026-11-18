// 單一持有部位的交易回放：移動平均成本法（docs/02 §2.1）。與 core/python/dca_core/ledger.py 一一對應。
import type { ISODate } from "./date";
import { Decimal, ZERO } from "./decimal";

export type TxType = "BUY" | "SELL" | "DIVIDEND_CASH" | "DIVIDEND_STOCK" | "DIVIDEND_REINVEST" | "FEE" | "SPLIT_ADJUST";
export const TX_TYPES: TxType[] = ["BUY", "SELL", "DIVIDEND_CASH", "DIVIDEND_STOCK", "DIVIDEND_REINVEST", "FEE", "SPLIT_ADJUST"];

export class LedgerError extends Error {
  constructor(readonly code: string, message = "") {
    super(message ? `${code}: ${message}` : code);
  }
}

export interface Transaction {
  type: TxType;
  tradeDate: ISODate;
  currency: string;
  grossAmount?: Decimal;
  price?: Decimal | null;
  quantity?: Decimal | null;
  fee?: Decimal;
  tax?: Decimal;
  otherCost?: Decimal;
  costCurrency?: string | null;
  /** 1 單位 currency = ? TWD */
  fxRateAtTrade?: Decimal | null;
  seq?: number;
}

export interface Position {
  quantity: Decimal;
  costBasis: Decimal;
  reinvestedCost: Decimal;
  historicalInvested: Decimal;
  realizedPnl: Decimal;
  dividendsNet: Decimal;
  standaloneFees: Decimal;
  lastTradePrice: Decimal | null;
}

export const investedCurrent = (p: Position) => p.costBasis.minus(p.reinvestedCost);
export const avgCost = (p: Position) => (p.quantity.isZero() ? null : p.costBasis.div(p.quantity));

export type FxFallback = (from: string, to: string, date: ISODate) => Decimal;

function costsInCcy(t: Transaction, fb?: FxFallback): Decimal {
  const total = (t.fee ?? ZERO).plus(t.tax ?? ZERO).plus(t.otherCost ?? ZERO);
  const cc = t.costCurrency ?? t.currency;
  if (cc === t.currency || total.isZero()) return total;
  const r = t.fxRateAtTrade;
  if (cc === "TWD" && r && !r.isZero()) return total.div(r);
  if (t.currency === "TWD" && r && !r.isZero()) return total.times(r);
  if (!fb) throw new LedgerError("FX_REQUIRED", `${cc}->${t.currency} on ${t.tradeDate}`);
  return total.times(fb(cc, t.currency, t.tradeDate));
}

function reqQty(t: Transaction): Decimal {
  if (!t.quantity || t.quantity.lte(0)) throw new LedgerError("INVALID_QUANTITY", `${t.type} on ${t.tradeDate}`);
  return t.quantity;
}

export function buildPosition(txs: Transaction[], asOf?: ISODate | null, fb?: FxFallback): Position {
  let qty = ZERO, cost = ZERO, reinv = ZERO, hist = ZERO, realized = ZERO, divs = ZERO, fees = ZERO;
  let last: Decimal | null = null;
  const ordered = txs.map((t, i) => [t, i] as const).sort(([a, ai], [b, bi]) =>
    a.tradeDate < b.tradeDate ? -1 : a.tradeDate > b.tradeDate ? 1 : (a.seq ?? 0) - (b.seq ?? 0) || ai - bi);
  for (const [t] of ordered) {
    if (!TX_TYPES.includes(t.type)) throw new LedgerError("UNKNOWN_TYPE", t.type);
    if (asOf && t.tradeDate > asOf) continue;
    const extra = costsInCcy(t, fb);
    const gross = t.grossAmount ?? ZERO;
    switch (t.type) {
      case "BUY": {
        const q = reqQty(t);
        const total = gross.plus(extra);
        qty = qty.plus(q);
        cost = cost.plus(total);
        hist = hist.plus(total);
        if (t.price) last = t.price;
        break;
      }
      case "SELL": {
        const q = reqQty(t);
        if (q.gt(qty)) throw new LedgerError("OVERSELL", `sell ${q} > holding ${qty} on ${t.tradeDate}`);
        const removed = cost.times(q).div(qty);
        const removedReinv = reinv.times(q).div(qty);
        realized = realized.plus(gross.minus(extra).minus(removed));
        qty = qty.minus(q);
        if (qty.isZero()) {
          cost = ZERO;
          reinv = ZERO;
        } else {
          cost = cost.minus(removed);
          reinv = reinv.minus(removedReinv);
        }
        if (t.price) last = t.price;
        break;
      }
      case "DIVIDEND_CASH":
        divs = divs.plus(gross.minus(extra));
        break;
      case "DIVIDEND_REINVEST": {
        const q = reqQty(t);
        const net = gross.minus(extra);
        divs = divs.plus(net);
        qty = qty.plus(q);
        cost = cost.plus(net);
        reinv = reinv.plus(net);
        if (t.price) last = t.price;
        break;
      }
      case "DIVIDEND_STOCK":
        qty = qty.plus(reqQty(t));
        break;
      case "SPLIT_ADJUST":
        qty = qty.times(reqQty(t));
        break;
      case "FEE":
        fees = fees.plus(gross.plus(extra));
        break;
    }
  }
  return { quantity: qty, costBasis: cost, reinvestedCost: reinv, historicalInvested: hist, realizedPnl: realized,
           dividendsNet: divs, standaloneFees: fees, lastTradePrice: last };
}
