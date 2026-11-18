// 價格與匯率解析、換算、合併總覽（docs/02 §2、docs/05 §3）。與 valuation.py 一一對應。
import type { ISODate } from "./date";
import { Decimal, ONE, ZERO } from "./decimal";
import { type Position } from "./ledger";

export type PriceSource = "MANUAL" | "AUTO" | "LAST_TRADE" | "COST" | "NONE";

export interface Override {
  value: Decimal;
  effectiveDate: ISODate;
  setAt: string;
  active: boolean;
}

export interface PriceInput {
  overrides?: Override[];
  autoValue?: Decimal | null;
  autoDataDate?: ISODate | null;
}

export function activeOverride(overrides: Override[] | undefined, asOf: ISODate): Override | null {
  let best: Override | null = null;
  for (const o of overrides ?? []) {
    if (!o.active || o.effectiveDate > asOf) continue;
    if (!best || o.effectiveDate > best.effectiveDate || (o.effectiveDate === best.effectiveDate && o.setAt > best.setAt)) best = o;
  }
  return best;
}

/** 手動值 → 自動行情 → 最後成交價 → 無 */
export function resolvePrice(inp: PriceInput | null | undefined, asOf: ISODate, lastTrade: Decimal | null): [Decimal | null, PriceSource] {
  if (inp) {
    const o = activeOverride(inp.overrides, asOf);
    if (o) return [o.value, "MANUAL"];
    if (inp.autoValue) return [inp.autoValue, "AUTO"];
  }
  if (lastTrade) return [lastTrade, "LAST_TRADE"];
  return [null, "NONE"];
}

export function resolveFx(ccy: string, inp: PriceInput | null | undefined, asOf: ISODate): [Decimal | null, PriceSource] {
  if (ccy === "TWD") return [ONE, "AUTO"];
  if (inp) {
    const o = activeOverride(inp.overrides, asOf);
    if (o) return [o.value, "MANUAL"];
    if (inp.autoValue) return [inp.autoValue, "AUTO"];
  }
  return [null, "NONE"];
}

export function convert(amount: Decimal, ccy: string, view: string, rates: Map<string, Decimal>): Decimal | null {
  if (ccy === view) return amount;
  const f = ccy === "TWD" ? ONE : rates.get(ccy);
  const t = view === "TWD" ? ONE : rates.get(view);
  if (!f || !t) return null;
  return amount.times(f).div(t);
}

export interface Holding {
  portfolioId: string;
  instrumentId: string;
  currency: string;
  position: Position;
  includeInOverview?: boolean;
}

export interface HoldingRow {
  instrumentId: string;
  currency: string;
  quantity: Decimal;
  avgCost: Decimal | null;
  price: Decimal | null;
  priceSource: PriceSource;
  marketValue: Decimal;
  marketValueView: Decimal | null;
}

export interface Overview {
  view: string;
  totalAssets: Decimal;
  investedCurrent: Decimal;
  historicalInvested: Decimal;
  pnlExDiv: Decimal;
  pnlIncDiv: Decimal;
  returnExDiv: Decimal | null;
  returnIncDiv: Decimal | null;
  rows: HoldingRow[];
  missingFx: string[];
  estimatedInstruments: string[];
}

export function overview(holdings: Holding[], prices: Map<string, PriceInput>, fx: Map<string, PriceInput>, view: string, asOf: ISODate): Overview {
  const rates = new Map<string, Decimal>();
  const missing = new Set<string>();
  for (const c of new Set([...holdings.map((h) => h.currency), view])) {
    const [r] = resolveFx(c, fx.get(c), asOf);
    if (r) rates.set(c, r);
    else missing.add(c);
  }
  type M = { currency: string; qty: Decimal; cost: Decimal; reinv: Decimal; hist: Decimal; realized: Decimal; divs: Decimal; fees: Decimal; last: Decimal | null };
  const merged = new Map<string, M>();
  for (const h of holdings) {
    if (h.includeInOverview === false) continue;
    const m = merged.get(h.instrumentId) ?? { currency: h.currency, qty: ZERO, cost: ZERO, reinv: ZERO, hist: ZERO, realized: ZERO, divs: ZERO, fees: ZERO, last: null };
    const p = h.position;
    m.qty = m.qty.plus(p.quantity);
    m.cost = m.cost.plus(p.costBasis);
    m.reinv = m.reinv.plus(p.reinvestedCost);
    m.hist = m.hist.plus(p.historicalInvested);
    m.realized = m.realized.plus(p.realizedPnl);
    m.divs = m.divs.plus(p.dividendsNet);
    m.fees = m.fees.plus(p.standaloneFees);
    if (p.lastTradePrice) m.last = p.lastTradePrice;
    merged.set(h.instrumentId, m);
  }
  let total = ZERO, inv = ZERO, hist = ZERO, ex = ZERO, divs = ZERO;
  const rows: HoldingRow[] = [];
  const estimated: string[] = [];
  for (const iid of [...merged.keys()].sort()) {
    const m = merged.get(iid)!;
    let [price, src] = resolvePrice(prices.get(iid), asOf, m.last);
    let mv: Decimal;
    if (price) mv = m.qty.times(price);
    else {
      mv = m.cost;
      src = "COST";
    }
    if ((src === "LAST_TRADE" || src === "COST") && !m.qty.isZero()) estimated.push(iid);
    const mvV = missing.has(view) ? null : convert(mv, m.currency, view, rates);
    rows.push({ instrumentId: iid, currency: m.currency, quantity: m.qty, avgCost: m.qty.isZero() ? null : m.cost.div(m.qty), price, priceSource: src, marketValue: mv, marketValueView: mvV });
    if (!mvV) continue;
    const cv = (x: Decimal) => convert(x, m.currency, view, rates)!;
    total = total.plus(mvV);
    inv = inv.plus(cv(m.cost.minus(m.reinv)));
    hist = hist.plus(cv(m.hist));
    ex = ex.plus(cv(mv.minus(m.cost).plus(m.realized).minus(m.fees)));
    divs = divs.plus(cv(m.divs));
  }
  const inc = ex.plus(divs);
  return { view, totalAssets: total, investedCurrent: inv, historicalInvested: hist, pnlExDiv: ex, pnlIncDiv: inc,
           returnExDiv: hist.isZero() ? null : ex.div(hist), returnIncDiv: hist.isZero() ? null : inc.div(hist),
           rows, missingFx: [...missing].sort(), estimatedInstruments: estimated };
}
