// 本機投資資料的唯一入口（與 ios/DCAKit PortfolioBook 相同規則）：先驗證、再寫入。
import { addDays, isValid, marketToday, type ISODate } from "../core/date";
import { D, Decimal, ZERO } from "../core/decimal";
import { buildPosition, LedgerError, type FxFallback, type Transaction, type TxType } from "../core/ledger";
import { dueOccurrences, TradingCalendar, upcomingOccurrences, validatePlan, type Occurrence, type Plan } from "../core/schedule";
import { monthlySnapshots, Series, type MonthPoint, type SnapshotHolding } from "../core/snapshots";
import { convert, overview as coreOverview, resolveFx, resolvePrice, type Holding, type Override, type Overview, type PriceInput, type PriceSource } from "../core/valuation";
import type { KV } from "./storage";

export const DATA_KEY = "portfolio.data.v1";
export const SCHEMA_VERSION = 1;

export type Market = "TW" | "US" | "JP" | "FUND_TW";
export const currencyOf = (m: string) => (m === "US" ? "USD" : m === "JP" ? "JPY" : "TWD");
const calendarKey = (m: string) => (m === "FUND_TW" ? "TW" : m);

export interface Portfolio { id: string; name: string; note?: string; colorHex: string; defaultCurrency: string; includeInOverview: boolean; sortOrder: number; archivedAt?: string | null; createdAt: string; updatedAt: string }
export interface Instrument { id: string; market: string; board?: string | null; symbol: string; name: string; assetType: string; currency: string; isUserDefined: boolean }
export interface PlanRecord {
  id: string; portfolioId: string; instrumentId: string; amountMode: "AMOUNT" | "QUANTITY"; amount: string; currency: string;
  frequency: "WEEKLY" | "MONTHLY" | "DATES"; weekdays: number[]; monthDays: number[]; specificDates: ISODate[];
  holidayRule: "NEXT_TRADING_DAY" | "PREV_TRADING_DAY"; startDate: ISODate; endDate?: ISODate | null; generateFrom: ISODate;
  feeMode: "FIXED" | "RATE"; feeValue: string; feeMin: string; paused: boolean; note?: string;
}
export interface OccurrenceRecord { id: string; planId: string; periodKey: string; nominalDate: ISODate; scheduledDate: ISODate; adjustReasons: string[]; mergedKeys: string[]; calendarUnknown: boolean; status: "PENDING" | "CONFIRMED" | "SKIPPED"; estPrice?: string | null; estQuantity?: string | null; estAmount?: string | null; transactionId?: string | null }
export interface TransactionRecord { id: string; portfolioId: string; instrumentId: string; type: TxType; tradeDate: ISODate; price?: string | null; quantity?: string | null; grossAmount: string; fee: string; tax: string; otherCost: string; costCurrency?: string | null; currency: string; fxRateAtTrade?: string | null; occurrenceId?: string | null; note?: string; seq: number; createdAt: string; updatedAt: string }
export interface OverrideRecord { id: string; key: string; value: string; effectiveDate: ISODate; setAt: string; active: boolean; note?: string }
export interface CacheEntry { value: string; dataDate: ISODate; sourceId: string; sourceURL: string; attribution: string; fetchedAt: string }
export interface HistoryPoint { date: ISODate; value: string }

export interface AppData {
  schemaVersion: number;
  portfolios: Portfolio[];
  instruments: Instrument[];
  plans: PlanRecord[];
  occurrences: OccurrenceRecord[];
  transactions: TransactionRecord[];
  overrides: OverrideRecord[];
  priceCache: Record<string, CacheEntry>;
  priceHistory: Record<string, HistoryPoint[]>;
  fxCache: Record<string, CacheEntry>;
  holidays: Record<string, ISODate[]>;
  holidaysKnownThrough: Record<string, ISODate>;
  lastRefresh: Record<string, string>;
  nextSeq: number;
}

export const emptyData = (): AppData => ({
  schemaVersion: SCHEMA_VERSION, portfolios: [], instruments: [], plans: [], occurrences: [], transactions: [], overrides: [],
  priceCache: {}, priceHistory: {}, fxCache: {}, holidays: {}, holidaysKnownThrough: {}, lastRefresh: {}, nextSeq: 1,
});

export class BookError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
  }
}

export interface QuoteSnapshot { market: string; symbol: string; close: string; dataDate: ISODate; sourceId: string; sourceURL: string; attribution: string }
export interface ConfirmInput { tradeDate: ISODate; price: string; quantity: string; grossAmount?: string; fee?: string; tax?: string; otherCost?: string; costCurrency?: string | null; fxRateAtTrade?: string | null }

const uid = () => crypto.randomUUID();
const dec = (s: string | null | undefined) => (s === null || s === undefined || s === "" ? null : D(s));
export const fxKey = (c: string) => `FX:${c}`;

export function parseDecimal(text: string): Decimal | null {
  const t = text.trim().replace(/,/g, "");
  if (!/^-?\d+(\.\d+)?$/.test(t)) return null;
  return D(t);
}

export class PortfolioBook {
  private constructor(public data: AppData, private readonly kv: KV, private readonly now: () => Date) {}

  static async open(kv: KV, now: () => Date = () => new Date()): Promise<PortfolioBook> {
    const d = (await kv.get<AppData>(DATA_KEY)) ?? emptyData();
    if (d.schemaVersion > SCHEMA_VERSION) throw new BookError("NEWER_SCHEMA", "資料來自較新版本的 App");
    return new PortfolioBook({ ...emptyData(), ...d }, kv, now);
  }

  private async commit(d: AppData) {
    await this.kv.set(DATA_KEY, d);
    this.data = d;
  }

  private clone(): AppData {
    return structuredClone(this.data);
  }

  today(market = "TW"): ISODate {
    return marketToday(calendarKey(market), this.now());
  }

  // ---------- 投資組合 ----------
  get activePortfolios() {
    return this.data.portfolios.filter((p) => !p.archivedAt).sort((a, b) => a.sortOrder - b.sortOrder);
  }

  private static cleanName(n: string) {
    const t = n.trim();
    if ([...t].length < 1 || [...t].length > 20) throw new BookError("INVALID_NAME", "名稱需為 1～20 字");
    return t;
  }

  async createPortfolio(name: string, opts: Partial<Pick<Portfolio, "note" | "colorHex" | "defaultCurrency" | "includeInOverview">> = {}): Promise<Portfolio> {
    const n = PortfolioBook.cleanName(name);
    if (this.data.portfolios.some((p) => p.name === n)) throw new BookError("DUPLICATE_NAME", "名稱已存在");
    const t = this.now().toISOString();
    const p: Portfolio = { id: uid(), name: n, note: opts.note, colorHex: opts.colorHex ?? "#3B82F6", defaultCurrency: opts.defaultCurrency ?? "TWD",
                           includeInOverview: opts.includeInOverview ?? true, sortOrder: Math.max(-1, ...this.data.portfolios.map((x) => x.sortOrder)) + 1,
                           archivedAt: null, createdAt: t, updatedAt: t };
    const d = this.clone();
    d.portfolios.push(p);
    await this.commit(d);
    return p;
  }

  async updatePortfolio(p: Portfolio) {
    const name = PortfolioBook.cleanName(p.name);
    const d = this.clone();
    const i = d.portfolios.findIndex((x) => x.id === p.id);
    if (i < 0) throw new BookError("NOT_FOUND", "找不到資料");
    if (d.portfolios.some((x) => x.id !== p.id && x.name === name)) throw new BookError("DUPLICATE_NAME", "名稱已存在");
    d.portfolios[i] = { ...p, name, updatedAt: this.now().toISOString() };
    await this.commit(d);
  }

  async setArchived(id: string, archived: boolean) {
    const d = this.clone();
    const p = d.portfolios.find((x) => x.id === id);
    if (!p) throw new BookError("NOT_FOUND", "找不到資料");
    p.archivedAt = archived ? this.now().toISOString() : null;
    await this.commit(d);
  }

  /** 刪除組合及其計畫、期別、交易（畫面需先要求輸入 App 密碼）。 */
  async deletePortfolio(id: string) {
    const d = this.clone();
    if (!d.portfolios.some((p) => p.id === id)) throw new BookError("NOT_FOUND", "找不到資料");
    const planIds = new Set(d.plans.filter((p) => p.portfolioId === id).map((p) => p.id));
    d.portfolios = d.portfolios.filter((p) => p.id !== id);
    d.plans = d.plans.filter((p) => p.portfolioId !== id);
    d.occurrences = d.occurrences.filter((o) => !planIds.has(o.planId));
    d.transactions = d.transactions.filter((t) => t.portfolioId !== id);
    await this.commit(d);
  }

  // ---------- 標的 ----------
  async upsertInstrument(market: string, symbol: string, name: string, assetType: string, board: string | null = null, isUserDefined = false): Promise<Instrument> {
    const sym = symbol.trim().toUpperCase();
    if (!sym) throw new BookError("INVALID_NAME", "代號不可空白");
    const d = this.clone();
    const ex = d.instruments.find((i) => i.market === market && i.symbol === sym);
    if (ex) {
      ex.name = name;
      if (board) ex.board = board;
      await this.commit(d);
      return ex;
    }
    const inst: Instrument = { id: uid(), market, board, symbol: sym, name, assetType, currency: currencyOf(market), isUserDefined };
    d.instruments.push(inst);
    await this.commit(d);
    return inst;
  }

  instrument(id: string) {
    return this.data.instruments.find((i) => i.id === id);
  }

  // ---------- 定期定額 ----------
  private calendar(market: string) {
    const k = calendarKey(market);
    // 沒有休市表時：只排除週末，並讓所有日期標示「日曆未更新」
    return new TradingCalendar(new Set(this.data.holidays[k] ?? []), this.data.holidaysKnownThrough[k] ?? "1970-01-01");
  }

  static corePlan(p: PlanRecord): Plan {
    for (const d of [p.startDate, p.endDate, ...p.specificDates]) {
      if (d && !isValid(d)) throw new BookError("INVALID_PLAN", "日期格式錯誤");
    }
    const plan: Plan = { frequency: p.frequency, startDate: p.startDate, endDate: p.endDate ?? null, weekdays: p.weekdays,
                         monthDays: p.monthDays, specificDates: p.specificDates, holidayRule: p.holidayRule, paused: p.paused };
    try {
      validatePlan(plan);
    } catch (e) {
      throw new BookError("INVALID_PLAN", `計畫設定不完整（${(e as Error).message}）`);
    }
    return plan;
  }

  async createPlan(p: Omit<PlanRecord, "id" | "generateFrom"> & { id?: string }, catchUp: boolean): Promise<PlanRecord> {
    if (!this.data.portfolios.some((x) => x.id === p.portfolioId)) throw new BookError("NOT_FOUND", "找不到投資組合");
    const inst = this.instrument(p.instrumentId);
    if (!inst) throw new BookError("NOT_FOUND", "找不到標的");
    if (!(dec(p.amount)?.gt(0))) throw new BookError("INVALID_AMOUNT", "每期金額或數量需大於 0");
    const today = this.today(inst.market);
    const rec: PlanRecord = { ...p, id: p.id ?? uid(), generateFrom: catchUp || p.startDate > today ? p.startDate : today };
    PortfolioBook.corePlan(rec);
    const d = this.clone();
    d.plans.push(rec);
    await this.commit(d);
    return rec;
  }

  async updatePlan(p: PlanRecord) {
    if (!(dec(p.amount)?.gt(0))) throw new BookError("INVALID_AMOUNT", "每期金額或數量需大於 0");
    PortfolioBook.corePlan(p);
    const d = this.clone();
    const i = d.plans.findIndex((x) => x.id === p.id);
    if (i < 0) throw new BookError("NOT_FOUND", "找不到計畫");
    d.plans[i] = p;
    await this.commit(d);
  }

  /** 刪除計畫：移除尚未確認的期別，保留已確認的交易。 */
  async deletePlan(id: string) {
    const d = this.clone();
    d.plans = d.plans.filter((p) => p.id !== id);
    d.occurrences = d.occurrences.filter((o) => !(o.planId === id && o.status === "PENDING"));
    await this.commit(d);
  }

  previewUpcoming(p: PlanRecord, count = 6): Occurrence[] {
    const inst = this.instrument(p.instrumentId);
    if (!inst) return [];
    return upcomingOccurrences(PortfolioBook.corePlan(p), this.calendar(inst.market), this.today(inst.market), count);
  }

  /** 開啟 App 時呼叫：補產生到期但尚未存在的期別。重複呼叫不會重複產生。 */
  async generatePending(): Promise<OccurrenceRecord[]> {
    const d = this.clone();
    const created: OccurrenceRecord[] = [];
    for (const plan of d.plans) {
      if (plan.paused) continue;
      const inst = this.instrument(plan.instrumentId);
      if (!inst) continue;
      const existing = new Set(d.occurrences.filter((o) => o.planId === plan.id).map((o) => o.periodKey));
      const due = dueOccurrences(PortfolioBook.corePlan(plan), this.calendar(inst.market), this.today(inst.market), existing, plan.generateFrom);
      const [price] = this.currentPrice(inst);
      for (const o of due) {
        const amt = D(plan.amount);
        let estAmount: Decimal | null = null, estQty: Decimal | null = null;
        if (plan.amountMode === "AMOUNT") {
          estAmount = amt;
          if (price && price.gt(0)) estQty = amt.div(price);
        } else {
          estQty = amt;
          if (price) estAmount = amt.times(price);
        }
        created.push({ id: uid(), planId: plan.id, periodKey: o.periodKey, nominalDate: o.nominalDate, scheduledDate: o.scheduledDate,
                       adjustReasons: o.adjustReasons, mergedKeys: o.mergedKeys, calendarUnknown: o.calendarUnknown, status: "PENDING",
                       estPrice: price?.toString() ?? null, estQuantity: estQty?.toString() ?? null, estAmount: estAmount?.toString() ?? null });
      }
    }
    if (created.length) {
      d.occurrences.push(...created);
      await this.commit(d);
    }
    return created;
  }

  get pendingOccurrences(): OccurrenceRecord[] {
    return this.data.occurrences.filter((o) => o.status === "PENDING")
      .sort((a, b) => (a.scheduledDate + a.periodKey < b.scheduledDate + b.periodKey ? -1 : 1));
  }

  async confirm(occurrenceId: string, input: ConfirmInput): Promise<TransactionRecord> {
    const o = this.data.occurrences.find((x) => x.id === occurrenceId);
    if (!o) throw new BookError("NOT_FOUND", "找不到期別");
    if (o.status !== "PENDING") throw new BookError("NOT_PENDING", "這一期已處理");
    const plan = this.data.plans.find((p) => p.id === o.planId);
    const inst = plan && this.instrument(plan.instrumentId);
    if (!plan || !inst) throw new BookError("NOT_FOUND", "找不到計畫");
    const price = dec(input.price), qty = dec(input.quantity);
    if (!price?.gt(0) || !qty?.gt(0)) throw new BookError("INVALID_AMOUNT", "價格與數量需大於 0");
    const gross = dec(input.grossAmount) ?? price.times(qty);
    const t = this.now().toISOString();
    const tx: TransactionRecord = { id: uid(), portfolioId: plan.portfolioId, instrumentId: inst.id, type: "BUY", tradeDate: input.tradeDate,
                                    price: price.toString(), quantity: qty.toString(), grossAmount: gross.toString(), fee: input.fee || "0",
                                    tax: input.tax || "0", otherCost: input.otherCost || "0", costCurrency: input.costCurrency ?? null,
                                    currency: inst.currency, fxRateAtTrade: input.fxRateAtTrade ?? null, occurrenceId, seq: 0, createdAt: t, updatedAt: t };
    const d = this.withTransaction(tx, this.clone());
    const oo = d.occurrences.find((x) => x.id === occurrenceId)!;
    oo.status = "CONFIRMED";
    oo.transactionId = tx.id;
    await this.commit(d);
    return d.transactions[d.transactions.length - 1];
  }

  async skip(occurrenceId: string) {
    const d = this.clone();
    const o = d.occurrences.find((x) => x.id === occurrenceId);
    if (!o) throw new BookError("NOT_FOUND", "找不到期別");
    if (o.status !== "PENDING") throw new BookError("NOT_PENDING", "這一期已處理");
    o.status = "SKIPPED";
    await this.commit(d);
  }

  // ---------- 交易 ----------
  static coreTx(t: TransactionRecord): Transaction {
    if (!isValid(t.tradeDate)) throw new BookError("INVALID_DATE", `日期格式錯誤：${t.tradeDate}`);
    return { type: t.type, tradeDate: t.tradeDate, currency: t.currency, grossAmount: D(t.grossAmount || "0"), price: dec(t.price),
             quantity: dec(t.quantity), fee: D(t.fee || "0"), tax: D(t.tax || "0"), otherCost: D(t.otherCost || "0"),
             costCurrency: t.costCurrency ?? null, fxRateAtTrade: dec(t.fxRateAtTrade), seq: t.seq };
  }

  private requireFeeRate(t: TransactionRecord, d: AppData) {
    const cc = t.costCurrency;
    if (!cc || cc === t.currency) return;
    const costs = D(t.fee || "0").plus(t.tax || "0").plus(t.otherCost || "0");
    if (costs.isZero()) return;
    const r = dec(t.fxRateAtTrade);
    if (r?.gt(0) && (cc === "TWD" || t.currency === "TWD")) return;
    if (convert(D(1), cc, t.currency, this.currentRates(d)) === null) throw new BookError("INVALID_AMOUNT", "費用幣別與標的不同，請填入交易日匯率");
  }

  private validatePosition(portfolioId: string, instrumentId: string, d: AppData) {
    const txs = d.transactions.filter((t) => t.portfolioId === portfolioId && t.instrumentId === instrumentId).map(PortfolioBook.coreTx);
    try {
      buildPosition(txs, null, this.fxFallback(d));
    } catch (e) {
      if (e instanceof LedgerError) throw new BookError(e.code, e.code === "OVERSELL" ? "賣出數量超過持有數量" : `交易資料不正確（${e.code}）`);
      throw e;
    }
  }

  private withTransaction(tx: TransactionRecord, d: AppData): AppData {
    this.requireFeeRate(tx, d);
    tx.seq = d.nextSeq;
    d.nextSeq += 1;
    d.transactions.push(tx);
    this.validatePosition(tx.portfolioId, tx.instrumentId, d);
    return d;
  }

  async addTransaction(tx: Omit<TransactionRecord, "id" | "seq" | "createdAt" | "updatedAt"> & { id?: string }): Promise<TransactionRecord> {
    if (!this.data.portfolios.some((p) => p.id === tx.portfolioId) || !this.instrument(tx.instrumentId)) throw new BookError("NOT_FOUND", "找不到資料");
    const t = this.now().toISOString();
    const rec: TransactionRecord = { ...tx, id: tx.id ?? uid(), seq: 0, createdAt: t, updatedAt: t };
    PortfolioBook.coreTx(rec);
    const d = this.withTransaction(rec, this.clone());
    await this.commit(d);
    return rec;
  }

  async updateTransaction(tx: TransactionRecord) {
    PortfolioBook.coreTx(tx);
    const d = this.clone();
    this.requireFeeRate(tx, d);
    const i = d.transactions.findIndex((x) => x.id === tx.id);
    if (i < 0) throw new BookError("NOT_FOUND", "找不到資料");
    d.transactions[i] = { ...tx, seq: d.transactions[i].seq, updatedAt: this.now().toISOString() };
    this.validatePosition(tx.portfolioId, tx.instrumentId, d);
    await this.commit(d);
  }

  /** 刪除交易；若由定期定額確認而來，該期別回到「待確認」。 */
  async deleteTransaction(id: string) {
    const d = this.clone();
    const tx = d.transactions.find((t) => t.id === id);
    if (!tx) throw new BookError("NOT_FOUND", "找不到資料");
    d.transactions = d.transactions.filter((t) => t.id !== id);
    this.validatePosition(tx.portfolioId, tx.instrumentId, d);
    const o = tx.occurrenceId ? d.occurrences.find((x) => x.id === tx.occurrenceId) : null;
    if (o) {
      o.status = "PENDING";
      o.transactionId = null;
    }
    await this.commit(d);
  }

  transactions(portfolioId?: string, instrumentId?: string) {
    return this.data.transactions
      .filter((t) => (!portfolioId || t.portfolioId === portfolioId) && (!instrumentId || t.instrumentId === instrumentId))
      .sort((a, b) => (a.tradeDate === b.tradeDate ? b.seq - a.seq : a.tradeDate < b.tradeDate ? 1 : -1));
  }

  // ---------- 手動值（docs/05 §3） ----------
  private async addOverride(key: string, value: string, effectiveDate: ISODate, note?: string) {
    if (!dec(value)?.gt(0)) throw new BookError("INVALID_AMOUNT", "數值需大於 0");
    if (!isValid(effectiveDate)) throw new BookError("INVALID_DATE", "日期格式錯誤");
    const d = this.clone();
    d.overrides.push({ id: uid(), key, value: D(value).toString(), effectiveDate, setAt: this.now().toISOString(), active: true, note });
    await this.commit(d);
  }

  setManualPrice(instrumentId: string, value: string, effectiveDate: ISODate, note?: string) {
    if (!this.instrument(instrumentId)) throw new BookError("NOT_FOUND", "找不到標的");
    return this.addOverride(instrumentId, value, effectiveDate, note);
  }

  setManualFx(currency: string, value: string, effectiveDate: ISODate, note?: string) {
    return this.addOverride(fxKey(currency), value, effectiveDate, note);
  }

  /** 只有使用者按「改回自動」才會停用手動值；自動更新永遠不會。 */
  async revertToAuto(key: string) {
    const d = this.clone();
    for (const o of d.overrides) if (o.key === key) o.active = false;
    await this.commit(d);
  }

  activeOverride(key: string): OverrideRecord | null {
    const xs = this.data.overrides.filter((o) => o.key === key && o.active);
    return xs.sort((a, b) => (a.effectiveDate + a.setAt < b.effectiveDate + b.setAt ? 1 : -1))[0] ?? null;
  }

  private coreOverrides(key: string, d: AppData): Override[] {
    return d.overrides.filter((o) => o.key === key).map((o) => ({ value: D(o.value), effectiveDate: o.effectiveDate, setAt: o.setAt, active: o.active }));
  }

  // ---------- 自動更新（只寫快取，不碰手動值） ----------
  async applyQuotes(quotes: QuoteSnapshot[], fetchedAt?: Date): Promise<number> {
    const d = this.clone();
    let n = 0;
    const t = (fetchedAt ?? this.now()).toISOString();
    for (const q of quotes) {
      const inst = d.instruments.find((i) => i.market === q.market && i.symbol === q.symbol);
      if (!inst) continue;
      const old = d.priceCache[inst.id];
      if (!old || old.dataDate <= q.dataDate) {
        d.priceCache[inst.id] = { value: q.close, dataDate: q.dataDate, sourceId: q.sourceId, sourceURL: q.sourceURL, attribution: q.attribution, fetchedAt: t };
      }
      // 較舊的資料日不覆蓋快取，但仍記入歷史（月損益圖需要）
      const hist = (d.priceHistory[inst.id] ?? []).filter((p) => p.date !== q.dataDate);
      hist.push({ date: q.dataDate, value: q.close });
      hist.sort((a, b) => (a.date < b.date ? -1 : 1));
      d.priceHistory[inst.id] = hist;
      n += 1;
    }
    await this.commit(d);
    return n;
  }

  async markRefreshed(key: string, at?: Date) {
    const d = this.clone();
    d.lastRefresh[key] = (at ?? this.now()).toISOString();
    await this.commit(d);
  }

  // ---------- 估值 ----------
  private priceInput(inst: Instrument, d: AppData): PriceInput {
    const c = d.priceCache[inst.id];
    return { overrides: this.coreOverrides(inst.id, d), autoValue: c ? D(c.value) : null, autoDataDate: c?.dataDate ?? null };
  }

  private fxInput(ccy: string, d: AppData): PriceInput {
    const c = d.fxCache[ccy];
    return { overrides: this.coreOverrides(fxKey(ccy), d), autoValue: c ? D(c.value) : null, autoDataDate: c?.dataDate ?? null };
  }

  currentPrice(inst: Instrument): [Decimal | null, PriceSource] {
    return resolvePrice(this.priceInput(inst, this.data), this.today(inst.market), null);
  }

  currentFx(ccy: string): [Decimal | null, PriceSource] {
    return resolveFx(ccy, this.fxInput(ccy, this.data), this.today("TW"));
  }

  private currentRates(d: AppData) {
    const r = new Map<string, Decimal>();
    for (const c of new Set([...d.instruments.map((i) => i.currency), "USD", "JPY"])) {
      const [v] = resolveFx(c, this.fxInput(c, d), this.today("TW"));
      if (v) r.set(c, v);
    }
    return r;
  }

  private fxFallback(d: AppData): FxFallback {
    const rates = this.currentRates(d);
    return (from, to) => convert(D(1), from, to, rates) ?? ZERO;
  }

  overview(view: string) {
    const d = this.data;
    const included = new Set(d.portfolios.filter((p) => p.includeInOverview).map((p) => p.id));
    const groups = new Map<string, TransactionRecord[]>();
    for (const t of d.transactions) {
      const k = `${t.portfolioId}|${t.instrumentId}`;
      groups.set(k, [...(groups.get(k) ?? []), t]);
    }
    const holdings: Holding[] = [];
    const broken: string[] = [];
    for (const txs of groups.values()) {
      const inst = this.instrument(txs[0].instrumentId);
      if (!inst) continue;
      try {
        holdings.push({ portfolioId: txs[0].portfolioId, instrumentId: inst.id, currency: inst.currency,
                        position: buildPosition(txs.map(PortfolioBook.coreTx), null, this.fxFallback(d)),
                        includeInOverview: included.has(txs[0].portfolioId) });
      } catch {
        broken.push(`${inst.market}:${inst.symbol}`);
      }
    }
    const prices = new Map(d.instruments.map((i) => [i.id, this.priceInput(i, d)]));
    const fx = new Map(["USD", "JPY"].map((c) => [c, this.fxInput(c, d)]));
    const ov: Overview = coreOverview(holdings, prices, fx, view, this.today("TW"));
    const rates = this.currentRates(d);
    let total = ZERO;
    let unconvertible = 0;
    const pend = this.pendingOccurrences;
    for (const o of pend) {
      const plan = d.plans.find((p) => p.id === o.planId);
      const v = plan && o.estAmount ? convert(D(o.estAmount), plan.currency, view, rates) : null;
      if (v) total = total.plus(v);
      else unconvertible += 1;
    }
    return { overview: ov, pending: { count: pend.length, estimatedTotal: total, unconvertibleCount: unconvertible }, brokenHoldings: broken.sort() };
  }

  monthlyPoints(view: string, onlyCurrency?: string | null): MonthPoint[] {
    const d = this.data;
    const included = new Set(d.portfolios.filter((p) => p.includeInOverview).map((p) => p.id));
    const byInst = new Map<string, TransactionRecord[]>();
    for (const t of d.transactions) if (included.has(t.portfolioId)) byInst.set(t.instrumentId, [...(byInst.get(t.instrumentId) ?? []), t]);
    const hs: SnapshotHolding[] = [];
    for (const [iid, txs] of byInst) {
      const inst = this.instrument(iid);
      if (inst) hs.push({ instrumentId: iid, currency: inst.currency, transactions: txs.map(PortfolioBook.coreTx) });
    }
    const ph = new Map(d.instruments.map((i) => [i.id, new Series((d.priceHistory[i.id] ?? []).map((p) => [p.date, D(p.value)]), this.coreOverrides(i.id, d))]));
    const fh = new Map(["USD", "JPY"].map((c) => [c, new Series([], this.coreOverrides(fxKey(c), d))]));
    return monthlySnapshots(hs, ph, fh, view, this.today("TW"), onlyCurrency);
  }

  /** 「清除所有資料並重新開始」：由畫面在確認文字正確後呼叫。 */
  async wipeAll() {
    await this.kv.del(DATA_KEY);
    this.data = emptyData();
  }
}

export { addDays };
