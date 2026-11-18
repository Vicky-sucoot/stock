// core/testcases/*.json 共用測試案例（與 Python、Swift 相同）。
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { marketToday } from "../src/core/date";
import { D, Decimal } from "../src/core/decimal";
import { avgCost, buildPosition, investedCurrent, LedgerError, type Transaction } from "../src/core/ledger";
import { dueOccurrences, TradingCalendar, upcomingOccurrences, type Occurrence, type Plan } from "../src/core/schedule";
import { monthlySnapshots, Series } from "../src/core/snapshots";
import { overview, resolvePrice, type Override, type PriceInput } from "../src/core/valuation";

const dir = resolve(__dirname, "../../core/testcases");
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const load = (n: string): any => JSON.parse(readFileSync(resolve(dir, n), "utf-8"));
const q8 = (x: Decimal) => x.toDecimalPlaces(8, Decimal.ROUND_HALF_EVEN).toString();

function expectDec(actual: Decimal | null | undefined, expected: string | null | undefined, label: string) {
  if (expected === null || expected === undefined) {
    expect(actual ?? null, label).toBeNull();
    return;
  }
  expect(actual, label).toBeTruthy();
  expect(q8(actual!), label).toBe(q8(D(expected)));
}

const S = load("schedule_cases.json");
const cal = (name: string) => new TradingCalendar(new Set(S.calendars[name].holidays), S.calendars[name].known_through ?? null);
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const plan = (p: any): Plan => ({
  frequency: p.frequency, startDate: p.start_date, endDate: p.end_date ?? null, weekdays: p.weekdays ?? [],
  monthDays: p.month_days ?? [], specificDates: p.specific_dates ?? [], holidayRule: p.holiday_rule ?? "NEXT_TRADING_DAY",
  paused: p.paused ?? false,
});
const occ = (o: Occurrence) => ({ period_key: o.periodKey, nominal_date: o.nominalDate, scheduled_date: o.scheduledDate,
                                   adjust_reasons: o.adjustReasons, merged_keys: o.mergedKeys });

describe("schedule", () => {
  for (const c of S.due_cases) {
    it(`${c.id} ${c.desc}`, () => {
      const got = dueOccurrences(plan(c.plan), cal(c.calendar), c.today, new Set(c.existing_keys), c.since ?? null);
      expect(got.map(occ)).toEqual(c.expect);
    });
  }
  for (const c of S.upcoming_cases) {
    it(`${c.id} ${c.desc}`, () => {
      expect(upcomingOccurrences(plan(c.plan), cal(c.calendar), c.today, c.count).map(occ)).toEqual(c.expect);
    });
  }
  for (const c of S.market_today_cases) {
    it(`${c.id} ${c.desc}`, () => expect(marketToday(c.market, new Date(c.now_utc))).toBe(c.expect));
  }
});

const dec = (v: string | null | undefined) => (v === null || v === undefined ? null : D(v));
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const tx = (t: any): Transaction => ({
  type: t.type, tradeDate: t.trade_date, currency: t.currency, grossAmount: D(t.gross_amount ?? "0"), price: dec(t.price),
  quantity: dec(t.quantity), fee: D(t.fee ?? "0"), tax: D(t.tax ?? "0"), otherCost: D(t.other_cost ?? "0"),
  costCurrency: t.cost_currency ?? null, fxRateAtTrade: dec(t.fx_rate_at_trade), seq: t.seq ?? 0,
});

describe("ledger", () => {
  for (const c of load("ledger_cases.json").cases) {
    it(`${c.id} ${c.desc}`, () => {
      const txs = c.transactions.map(tx);
      if (c.expect_error) {
        expect(() => buildPosition(txs, c.as_of)).toThrowError(LedgerError);
        try {
          buildPosition(txs, c.as_of);
        } catch (e) {
          expect((e as LedgerError).code).toBe(c.expect_error);
        }
        return;
      }
      const p = buildPosition(txs, c.as_of);
      const e = c.expect;
      expectDec(p.quantity, e.quantity, "quantity");
      expectDec(p.costBasis, e.cost_basis, "cost_basis");
      expectDec(p.reinvestedCost, e.reinvested_cost, "reinvested_cost");
      expectDec(p.historicalInvested, e.historical_invested, "historical_invested");
      expectDec(p.realizedPnl, e.realized_pnl, "realized_pnl");
      expectDec(p.dividendsNet, e.dividends_net, "dividends_net");
      expectDec(p.standaloneFees, e.standalone_fees, "standalone_fees");
      expectDec(p.lastTradePrice, e.last_trade_price, "last_trade_price");
      expectDec(investedCurrent(p), e.invested_current, "invested_current");
      expectDec(avgCost(p), e.avg_cost, "avg_cost");
    });
  }
});

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const ovr = (l: any[] | undefined): Override[] => (l ?? []).map((o) => ({ value: D(o.value), effectiveDate: o.effective_date, setAt: o.set_at, active: o.active ?? true }));
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const pin = (p: any): PriceInput | null => (p ? { overrides: ovr(p.overrides), autoValue: dec(p.auto_value), autoDataDate: p.auto_data_date ?? null } : null);

describe("valuation", () => {
  const V = load("valuation_cases.json");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const holdings = V.holdings.map((h: any) => ({ portfolioId: h.portfolio_id, instrumentId: h.instrument_id, currency: h.currency,
                                                 position: buildPosition(h.transactions.map(tx)), includeInOverview: h.include_in_overview ?? true }));
  const prices = new Map(Object.entries(V.prices).map(([k, v]) => [k, pin(v)!]));
  for (const c of V.overview_cases) {
    it(`${c.id} ${c.desc}`, () => {
      const fx = new Map(Object.entries(V.fx).filter(([k]) => !c.drop_fx.includes(k)).map(([k, v]) => [k, pin(v)!]));
      const ov = overview(holdings, prices, fx, c.view, V.as_of);
      const e = c.expect;
      expectDec(ov.totalAssets, e.total_assets, "total_assets");
      expectDec(ov.investedCurrent, e.invested_current, "invested_current");
      expectDec(ov.historicalInvested, e.historical_invested, "historical_invested");
      expectDec(ov.pnlExDiv, e.pnl_ex_div, "pnl_ex_div");
      expectDec(ov.pnlIncDiv, e.pnl_inc_div, "pnl_inc_div");
      expectDec(ov.returnExDiv, e.return_ex_div, "return_ex_div");
      expectDec(ov.returnIncDiv, e.return_inc_div, "return_inc_div");
      expect(ov.missingFx).toEqual(e.missing_fx);
      expect(ov.estimatedInstruments).toEqual(e.estimated_instruments);
      for (const [iid, er] of Object.entries(e.rows ?? {}) as [string, { quantity: string; avg_cost: string; price: string; price_source: string }][]) {
        const r = ov.rows.find((x) => x.instrumentId === iid)!;
        expectDec(r.quantity, er.quantity, `${iid}.quantity`);
        expectDec(r.avgCost, er.avg_cost, `${iid}.avg_cost`);
        expectDec(r.price, er.price, `${iid}.price`);
        expect(r.priceSource).toBe(er.price_source);
      }
    });
  }
  for (const c of V.resolve_price_cases) {
    it(`${c.id} ${c.desc}`, () => {
      const [v, src] = resolvePrice(pin(c.input), c.as_of, dec(c.last_trade_price));
      expectDec(v, c.expect.value, "value");
      expect(src).toBe(c.expect.source);
    });
  }
});

describe("snapshots", () => {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const series = (s: any) => new Series((s?.points ?? []).map((p: [string, string]) => [p[0], D(p[1])]), ovr(s?.overrides));
  for (const c of load("snapshot_cases.json").cases) {
    it(`${c.id} ${c.desc}`, () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const hs = c.holdings.map((h: any) => ({ instrumentId: h.instrument_id, currency: h.currency, transactions: h.transactions.map(tx) }));
      const ph = new Map(Object.entries(c.price_history).map(([k, v]) => [k, series(v)]));
      const fh = new Map(Object.entries(c.fx_history).map(([k, v]) => [k, series(v)]));
      const pts = monthlySnapshots(hs, ph, fh, c.view, c.as_of, c.only_currency ?? null);
      expect(pts.length).toBe(c.expect.length);
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      c.expect.forEach((e: any, i: number) => {
        const p = pts[i];
        expect(p.month).toBe(e.month);
        expect(p.date).toBe(e.date);
        for (const [k, key] of [["marketValue", "market_value"], ["investedCurrent", "invested_current"], ["historicalInvested", "historical_invested"], ["pnlExDiv", "pnl_ex_div"], ["pnlIncDiv", "pnl_inc_div"]] as const) {
          expectDec(p[k], e[key], `${e.month}.${key}`);
        }
        expect(p.estimated).toBe(e.estimated);
        expect(p.estimatedItems).toEqual(e.estimated_items);
        expect(p.missingFx).toEqual(e.missing_fx);
      });
    });
  }
});
