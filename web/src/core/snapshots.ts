// 全期間月資料點（docs/05 §5）。與 snapshots.py 一一對應。
import { daysInMonth, make, parts, type ISODate } from "./date";
import { Decimal, ZERO } from "./decimal";
import { buildPosition, investedCurrent, type Transaction } from "./ledger";
import { activeOverride, convert, type Override } from "./valuation";

export class Series {
  readonly points: [ISODate, Decimal][];
  constructor(points: [ISODate, Decimal][] = [], readonly overrides: Override[] = []) {
    this.points = [...points].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  }

  /** [value, valueDate, isManual] */
  at(d: ISODate): [Decimal | null, ISODate | null, boolean] {
    const o = activeOverride(this.overrides, d);
    if (o) return [o.value, d, true];
    let found: [ISODate, Decimal] | null = null;
    for (const p of this.points) {
      if (p[0] <= d) found = p;
      else break;
    }
    return found ? [found[1], found[0], false] : [null, null, false];
  }
}

export interface SnapshotHolding {
  instrumentId: string;
  currency: string;
  transactions: Transaction[];
  includeInOverview?: boolean;
}

export interface MonthPoint {
  month: string;
  date: ISODate;
  marketValue: Decimal;
  investedCurrent: Decimal;
  historicalInvested: Decimal;
  pnlExDiv: Decimal;
  pnlIncDiv: Decimal;
  estimated: boolean;
  estimatedItems: string[];
  missingFx: string[];
}

function monthEnds(first: ISODate, asOf: ISODate): [string, ISODate][] {
  const out: [string, ISODate][] = [];
  let [y, m] = parts(first);
  const [ay, am] = parts(asOf);
  while (y < ay || (y === ay && m <= am)) {
    const label = `${y}-${String(m).padStart(2, "0")}`;
    out.push([label, y === ay && m === am ? asOf : make(y, m, daysInMonth(y, m))]);
    m += 1;
    if (m === 13) {
      y += 1;
      m = 1;
    }
  }
  return out;
}

export function monthlySnapshots(holdings: SnapshotHolding[], priceHistory: Map<string, Series>, fxHistory: Map<string, Series>,
                                 view: string, asOf: ISODate, onlyCurrency?: string | null): MonthPoint[] {
  let hs = holdings.filter((h) => h.includeInOverview !== false);
  if (onlyCurrency) {
    hs = hs.filter((h) => h.currency === onlyCurrency);
    view = onlyCurrency;
  }
  const dates = hs.flatMap((h) => h.transactions.map((t) => t.tradeDate));
  if (!dates.length) return [];
  const first = dates.reduce((a, b) => (a < b ? a : b));
  const out: MonthPoint[] = [];
  for (const [month, d] of monthEnds(first, asOf)) {
    const monthStart = d.slice(0, 8) + "01";
    const rates = new Map<string, Decimal>();
    const est = new Set<string>();
    const missing = new Set<string>();
    const needed = onlyCurrency ? [] : [...new Set([...hs.map((h) => h.currency), view])];
    for (const c of needed) {
      if (c === "TWD") continue;
      const [v, vd, manual] = (fxHistory.get(c) ?? new Series()).at(d);
      if (!v) {
        missing.add(c);
        continue;
      }
      rates.set(c, v);
      if (!manual && vd && vd < monthStart) est.add(`FX:${c}`);
    }
    let mvT = ZERO, invT = ZERO, histT = ZERO, exT = ZERO, divT = ZERO;
    for (const h of hs) {
      const pos = buildPosition(h.transactions, d);
      if (pos.quantity.isZero() && pos.historicalInvested.isZero() && pos.dividendsNet.isZero() && pos.standaloneFees.isZero()) continue;
      let [p, pd, manual] = (priceHistory.get(h.instrumentId) ?? new Series()).at(d);
      let stale = !!p && !manual && !!pd && pd < monthStart;
      if (!p && pos.lastTradePrice) {
        p = pos.lastTradePrice;
        stale = true;
      }
      const mv = p ? pos.quantity.times(p) : pos.costBasis;
      if ((!p || stale) && !pos.quantity.isZero()) est.add(`PRICE:${h.instrumentId}`);
      if (missing.has(h.currency) || missing.has(view)) continue;
      const cv = (x: Decimal) => convert(x, h.currency, view, rates)!;
      mvT = mvT.plus(cv(mv));
      invT = invT.plus(cv(investedCurrent(pos)));
      histT = histT.plus(cv(pos.historicalInvested));
      exT = exT.plus(cv(mv.minus(pos.costBasis).plus(pos.realizedPnl).minus(pos.standaloneFees)));
      divT = divT.plus(cv(pos.dividendsNet));
    }
    const items = [...est].sort();
    out.push({ month, date: d, marketValue: mvT, investedCurrent: invT, historicalInvested: histT, pnlExDiv: exT,
               pnlIncDiv: exT.plus(divT), estimated: items.length > 0 || missing.size > 0, estimatedItems: items, missingFx: [...missing].sort() });
  }
  return out;
}
