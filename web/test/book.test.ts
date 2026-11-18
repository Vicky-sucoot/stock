import { beforeEach, describe, expect, it } from "vitest";
import { BookError, PortfolioBook, fxKey, type Instrument, type Portfolio } from "../src/app/book";
import { MemoryKV } from "../src/app/storage";

// 2026-11-18（週三）16:00 台灣時間
const WED_4PM = new Date("2026-11-18T08:00:00Z");

let kv: MemoryKV, book: PortfolioBook, portfolio: Portfolio, etf: Instrument;

const plan = (day = 31, start = "2026-09-01") => ({
  portfolioId: portfolio.id, instrumentId: etf.id, amountMode: "AMOUNT" as const, amount: "3000", currency: "TWD",
  frequency: "MONTHLY" as const, weekdays: [], monthDays: [day], specificDates: [], holidayRule: "NEXT_TRADING_DAY" as const,
  startDate: start, endDate: null, feeMode: "FIXED" as const, feeValue: "0", feeMin: "0", paused: false,
});
const quote = (symbol: string, close: string, dataDate: string, market = "TW") =>
  ({ market, symbol, close, dataDate, sourceId: "TEST", sourceURL: "https://example.invalid", attribution: "test" });
const buy = (instrumentId: string, date: string, price: string, qty: string, currency = "TWD", extra = {}) => ({
  portfolioId: portfolio.id, instrumentId, type: "BUY" as const, tradeDate: date, price, quantity: qty,
  grossAmount: String(Number(price) * Number(qty)), fee: "0", tax: "0", otherCost: "0", currency, ...extra,
});

async function err(p: Promise<unknown>) {
  try {
    await p;
  } catch (e) {
    return (e as BookError).code;
  }
  return null;
}

beforeEach(async () => {
  kv = new MemoryKV();
  book = await PortfolioBook.open(kv, () => WED_4PM);
  portfolio = await book.createPortfolio("長期");
  etf = await book.upsertInstrument("TW", "0050", "元大台灣50", "ETF");
});

describe("PortfolioBook", () => {
  it("validates portfolio names", async () => {
    expect(await err(book.createPortfolio("  "))).toBe("INVALID_NAME");
    expect(await err(book.createPortfolio("長".repeat(21)))).toBe("INVALID_NAME");
    expect(await err(book.createPortfolio(" 長期 "))).toBe("DUPLICATE_NAME");
    const b = await book.createPortfolio("教育金");
    expect(b.sortOrder).toBe(1);
    await book.setArchived(b.id, true);
    expect(book.activePortfolios.map((p) => p.name)).toEqual(["長期"]);
  });

  it("catch-up generates past periods with month-end and weekend rules; idempotent", async () => {
    await book.applyQuotes([quote("0050", "94", "2026-11-17")]);
    await book.createPlan(plan(), true);
    const created = await book.generatePending();
    expect(created.map((o) => o.periodKey)).toEqual(["2026-09#31", "2026-10#31"]);
    expect(created.map((o) => o.scheduledDate)).toEqual(["2026-09-30", "2026-11-02"]);
    expect(created.every((o) => o.calendarUnknown)).toBe(true);
    expect(await book.generatePending()).toHaveLength(0);
  });

  it("without catch-up only future periods", async () => {
    await book.createPlan(plan(), false);
    expect(await book.generatePending()).toHaveLength(0);
    expect(book.data.plans[0].generateFrom).toBe("2026-11-18");
  });

  it("confirm, skip, and delete restores pending; pending not counted in assets", async () => {
    await book.createPlan(plan(), true);
    await book.generatePending();
    expect(book.overview("TWD").overview.totalAssets.isZero()).toBe(true);
    const first = book.pendingOccurrences[0];
    const tx = await book.confirm(first.id, { tradeDate: "2026-09-30", price: "100", quantity: "30", fee: "20" });
    expect(tx.grossAmount).toBe("3000");
    expect(await err(book.confirm(first.id, { tradeDate: "2026-09-30", price: "1", quantity: "1" }))).toBe("NOT_PENDING");
    await book.skip(book.pendingOccurrences[0].id);
    expect(book.pendingOccurrences).toHaveLength(0);
    expect(book.overview("TWD").overview.historicalInvested.toString()).toBe("3020");
    await book.deleteTransaction(tx.id);
    expect(book.pendingOccurrences.map((o) => o.id)).toEqual([first.id]);
  });

  it("rejects oversell without changing data", async () => {
    await book.addTransaction(buy(etf.id, "2026-10-01", "100", "10"));
    expect(await err(book.addTransaction({ ...buy(etf.id, "2026-10-02", "100", "11"), type: "SELL" }))).toBe("OVERSELL");
    expect(book.data.transactions).toHaveLength(1);
  });

  it("manual price survives auto updates until the user reverts (AC-12)", async () => {
    await book.setManualPrice(etf.id, "100", "2026-11-01");
    for (let i = 0; i < 10; i++) await book.applyQuotes([quote("0050", `9${i}`, `2026-11-1${i % 8}`)]);
    expect(book.currentPrice(etf).map(String)).toEqual(["100", "MANUAL"]);
    await book.revertToAuto(etf.id);
    expect(book.currentPrice(etf)[1]).toBe("AUTO");
  });

  it("older quote is kept in history but does not overwrite cache", async () => {
    await book.applyQuotes([quote("0050", "95", "2026-11-18")]);
    await book.applyQuotes([quote("0050", "90", "2026-11-17")]);
    expect(book.currentPrice(etf)[0]!.toString()).toBe("95");
    expect(book.data.priceHistory[etf.id].map((p) => p.date)).toEqual(["2026-11-17", "2026-11-18"]);
  });

  it("overview converts with manual fx and flags missing fx", async () => {
    const aapl = await book.upsertInstrument("US", "aapl", "Apple", "STOCK");
    expect([aapl.symbol, aapl.currency]).toEqual(["AAPL", "USD"]);
    await book.addTransaction(buy(etf.id, "2026-10-01", "90", "10"));
    await book.addTransaction(buy(aapl.id, "2026-10-01", "200", "1", "USD"));
    await book.applyQuotes([quote("0050", "94", "2026-11-17"), quote("AAPL", "210", "2026-11-17", "US")]);
    const noFx = book.overview("TWD").overview;
    expect(noFx.missingFx).toEqual(["USD"]);
    expect(noFx.totalAssets.toString()).toBe("940");
    await book.setManualFx("USD", "32", "2026-11-01");
    const twd = book.overview("TWD").overview;
    expect(twd.totalAssets.toString()).toBe(String(940 + 210 * 32));
    expect(twd.pnlExDiv.toString()).toBe(String(40 + 10 * 32));
    expect(book.overview("USD").overview.totalAssets.toString()).toBe(String((940 + 210 * 32) / 32));
    expect(book.activeOverride(fxKey("USD"))?.value).toBe("32");
  });

  it("fee in another currency needs a rate", async () => {
    const aapl = await book.upsertInstrument("US", "AAPL", "Apple", "STOCK");
    const tx = buy(aapl.id, "2026-10-01", "100", "1", "USD", { fee: "30", costCurrency: "TWD" });
    expect(await err(book.addTransaction(tx))).toBe("INVALID_AMOUNT");
    await book.addTransaction({ ...tx, fxRateAtTrade: "30" });
    await book.setManualFx("USD", "32", "2026-10-01");
    expect(book.overview("USD").overview.historicalInvested.toString()).toBe("101");
  });

  it("delete portfolio cascades but keeps instruments", async () => {
    await book.createPlan(plan(), true);
    await book.generatePending();
    await book.confirm(book.pendingOccurrences[0].id, { tradeDate: "2026-09-30", price: "100", quantity: "30" });
    await book.deletePortfolio(portfolio.id);
    expect([book.data.plans.length, book.data.occurrences.length, book.data.transactions.length, book.data.instruments.length]).toEqual([0, 0, 0, 1]);
  });

  it("monthly points cover first trade month to today", async () => {
    await book.addTransaction(buy(etf.id, "2026-09-15", "90", "10"));
    await book.applyQuotes([quote("0050", "94", "2026-11-17")]);
    const pts = book.monthlyPoints("TWD");
    expect(pts.map((p) => p.month)).toEqual(["2026-09", "2026-10", "2026-11"]);
    expect(pts[0].estimated).toBe(true);
    expect(pts[2].marketValue.toString()).toBe("940");
    expect(pts[2].estimated).toBe(false);
  });

  it("persists to storage and reopens; wipe clears", async () => {
    const again = await PortfolioBook.open(kv, () => WED_4PM);
    expect(again.data.portfolios.map((p) => p.name)).toEqual(["長期"]);
    await again.wipeAll();
    expect((await PortfolioBook.open(kv)).data.portfolios).toHaveLength(0);
  });
});
