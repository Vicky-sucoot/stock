import DCACore
import Foundation
import XCTest
@testable import DCAKit

/// 2026-11-18（週三）16:00 台灣時間
let WED_4PM = Date(timeIntervalSince1970: 1_794_988_800)

func D(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }

final class DecAndStoreTests: XCTestCase {
    func testWedConstantIsWhatWeThink() throws {
        XCTAssertEqual(try marketToday(market: "TW", now: WED_4PM).iso, "2026-11-18")
    }

    func testDecKeepsFullPrecisionThroughJSON() throws {
        struct Box: Codable { var v: Dec }
        let original = Box(v: Dec(D("0.123456789012345678901")))
        let json = try JSONEncoder().encode(original)
        XCTAssertEqual(String(decoding: json, as: UTF8.self), #"{"v":"0.123456789012345678901"}"#)
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: json).v, original.v)
        XCTAssertThrowsError(try JSONDecoder().decode(Box.self, from: Data(#"{"v":"abc"}"#.utf8)))
        XCTAssertEqual(Dec(string: "1,234.5")?.value, D("1234.5"))
    }

    func testFileStoreRoundTripAndWipe() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONFileDataStore(url: dir.appendingPathComponent("data.json"))
        XCTAssertEqual(try store.load().portfolios.count, 0)
        let book = try PortfolioBook(store: store, now: { WED_4PM })
        try book.createPortfolio(name: "退休")
        let reloaded = try PortfolioBook(store: store, now: { WED_4PM })
        XCTAssertEqual(reloaded.data.portfolios.map(\.name), ["退休"])
        try reloaded.wipeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertEqual(reloaded.data.portfolios.count, 0)
    }

    func testRefusesNewerSchema() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("data.json")
        var d = AppData()
        d.schemaVersion = 99
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try e.encode(d).write(to: url)
        XCTAssertThrowsError(try JSONFileDataStore(url: url).load()) { XCTAssertEqual($0 as? DataStoreError, .newerSchema(99)) }
    }
}

final class BookTests: XCTestCase {
    var store: InMemoryDataStore!
    var book: PortfolioBook!
    var portfolio: Portfolio!
    var etf: Instrument!

    override func setUpWithError() throws {
        store = InMemoryDataStore()
        book = try PortfolioBook(store: store, now: { WED_4PM })
        portfolio = try book.createPortfolio(name: "長期")
        etf = try book.upsertInstrument(market: Market.tw, symbol: "0050", name: "元大台灣50", assetType: "ETF")
    }

    func quote(_ sym: String, _ close: String, _ date: String, market: String = Market.tw) -> QuoteSnapshot {
        QuoteSnapshot(market: market, symbol: sym, close: D(close), dataDate: LocalDate(iso: date)!,
                      sourceId: "TEST", sourceURL: "https://example.invalid", attribution: "test")
    }

    func monthlyPlan(_ day: Int = 31, start: String = "2026-09-01") -> PlanRecord {
        PlanRecord(portfolioId: portfolio.id, instrumentId: etf.id, amount: Dec(3000), currency: "TWD",
                   frequency: "MONTHLY", monthDays: [day], startDate: start)
    }

    func testPortfolioValidation() throws {
        XCTAssertThrowsError(try book.createPortfolio(name: "  ")) { XCTAssertEqual($0 as? BookError, .invalidName("名稱需為 1～20 字")) }
        XCTAssertThrowsError(try book.createPortfolio(name: String(repeating: "長", count: 21)))
        XCTAssertThrowsError(try book.createPortfolio(name: " 長期 ")) { XCTAssertEqual($0 as? BookError, .duplicateName) }
        let b = try book.createPortfolio(name: "教育金")
        XCTAssertEqual(b.sortOrder, 1)
        try book.setArchived(b.id, true)
        XCTAssertEqual(book.activePortfolios.map(\.name), ["長期"])
    }

    func testCatchUpGeneratesPastPeriodsWithMonthEndAndWeekendRules() throws {
        try book.applyQuotes([quote("0050", "94", "2026-11-17")])
        try book.createPlan(monthlyPlan(), catchUp: true)
        let created = try book.generatePending()
        XCTAssertEqual(created.map(\.periodKey), ["2026-09#31", "2026-10#31"])
        XCTAssertEqual(created.map(\.scheduledDate), ["2026-09-30", "2026-11-02"])  // 9 月取月底；10/31 週六順延
        XCTAssertEqual(created[0].adjustReasons, ["MONTH_END"])
        XCTAssertEqual(created[1].adjustReasons, ["HOLIDAY_FORWARD"])
        XCTAssertTrue(created.allSatisfy(\.calendarUnknown))  // 沒有休市表
        XCTAssertEqual(created[0].estAmount?.value, 3000)
        XCTAssertEqual(created[0].estQuantity?.value, D("3000") / D("94"))
        XCTAssertEqual(try book.generatePending().count, 0)  // AC-5：不重複產生
    }

    func testWithoutCatchUpOnlyFuturePeriods() throws {
        try book.createPlan(monthlyPlan(), catchUp: false)
        XCTAssertEqual(try book.generatePending().count, 0)
        XCTAssertEqual(book.data.plans[0].generateFrom, "2026-11-18")
    }

    func testPausedAndInvalidPlans() throws {
        var p = monthlyPlan()
        p.paused = true
        try book.createPlan(p, catchUp: true)
        XCTAssertEqual(try book.generatePending().count, 0)
        var bad = monthlyPlan()
        bad.amount = Dec(0)
        XCTAssertThrowsError(try book.createPlan(bad, catchUp: true))
        var bad2 = monthlyPlan()
        bad2.monthDays = []
        XCTAssertThrowsError(try book.createPlan(bad2, catchUp: true))
    }

    func testConfirmSkipAndDeleteRoundTrip() throws {
        try book.createPlan(monthlyPlan(), catchUp: true)
        try book.generatePending()
        XCTAssertEqual(book.overview(view: "TWD").pending.count, 2)
        // AC-6：待確認不計入資產
        XCTAssertEqual(book.overview(view: "TWD").overview.totalAssets, 0)

        let first = book.pendingOccurrences[0]
        let tx = try book.confirm(first.id, ConfirmInput(tradeDate: "2026-09-30", price: D("100"), quantity: D("30"), fee: D("20")))
        XCTAssertEqual(tx.grossAmount.value, 3000)
        XCTAssertEqual(tx.occurrenceId, first.id)
        XCTAssertThrowsError(try book.confirm(first.id, ConfirmInput(tradeDate: "2026-09-30", price: 1, quantity: 1))) {
            XCTAssertEqual($0 as? BookError, .occurrenceNotPending)
        }
        try book.skip(book.pendingOccurrences[0].id)
        XCTAssertEqual(book.pendingOccurrences.count, 0)

        let ov = book.overview(view: "TWD")
        XCTAssertEqual(ov.overview.historicalInvested, 3020)
        XCTAssertEqual(ov.overview.rows.first?.priceSource, .lastTrade)  // 尚無行情時以成交價估

        // 刪除交易後，期別回到待確認
        try book.deleteTransaction(tx.id)
        XCTAssertEqual(book.pendingOccurrences.map(\.id), [first.id])
    }

    func testOversellIsRejectedAndNothingChanges() throws {
        try book.addTransaction(TransactionRecord(portfolioId: portfolio.id, instrumentId: etf.id, type: .buy,
                                                  tradeDate: "2026-10-01", price: Dec(100), quantity: Dec(10),
                                                  grossAmount: Dec(1000), currency: "TWD"))
        let before = store.saveCount
        XCTAssertThrowsError(try book.addTransaction(TransactionRecord(portfolioId: portfolio.id, instrumentId: etf.id, type: .sell,
                                                                       tradeDate: "2026-10-02", price: Dec(100), quantity: Dec(11),
                                                                       grossAmount: Dec(1100), currency: "TWD"))) {
            XCTAssertEqual($0 as? BookError, .ledger("OVERSELL"))
        }
        XCTAssertEqual(store.saveCount, before)
        XCTAssertEqual(book.data.transactions.count, 1)
    }

    func testManualPriceSurvivesAutoUpdatesUntilUserReverts() throws {
        try book.setManualPrice(instrumentId: etf.id, value: 100, effectiveDate: "2026-11-01")
        for i in 0..<10 { try book.applyQuotes([quote("0050", "9\(i)", "2026-11-1\(i % 8)")]) }  // AC-12
        XCTAssertEqual(book.currentPrice(etf).0, 100)
        XCTAssertEqual(book.currentPrice(etf).1, .manual)
        try book.revertToAuto(key: etf.id.uuidString)
        XCTAssertEqual(book.currentPrice(etf).1, .auto)
    }

    func testOlderQuoteDoesNotOverwriteNewer() throws {
        try book.applyQuotes([quote("0050", "95", "2026-11-18")])
        try book.applyQuotes([quote("0050", "90", "2026-11-17")])
        XCTAssertEqual(book.currentPrice(etf).0, 95)
        XCTAssertEqual(book.data.priceHistory[etf.id.uuidString]?.map(\.date), ["2026-11-17", "2026-11-18"])
    }

    func testOverviewConvertsWithManualFxAndFlagsMissingFx() throws {
        let aapl = try book.upsertInstrument(market: Market.us, symbol: "aapl", name: "Apple", assetType: "STOCK")
        XCTAssertEqual(aapl.symbol, "AAPL")
        XCTAssertEqual(aapl.currency, "USD")
        try book.addTransaction(TransactionRecord(portfolioId: portfolio.id, instrumentId: etf.id, type: .buy,
                                                  tradeDate: "2026-10-01", price: Dec(90), quantity: Dec(10),
                                                  grossAmount: Dec(900), currency: "TWD"))
        try book.addTransaction(TransactionRecord(portfolioId: portfolio.id, instrumentId: aapl.id, type: .buy,
                                                  tradeDate: "2026-10-01", price: Dec(200), quantity: Dec(1),
                                                  grossAmount: Dec(200), currency: "USD"))
        try book.applyQuotes([quote("0050", "94", "2026-11-17"), quote("AAPL", "210", "2026-11-17", market: Market.us)])

        let noFx = book.overview(view: "TWD").overview
        XCTAssertEqual(noFx.missingFx, ["USD"])
        XCTAssertEqual(noFx.totalAssets, 940)

        try book.setManualFx(currency: "USD", value: 32, effectiveDate: "2026-11-01")
        let twd = book.overview(view: "TWD").overview
        XCTAssertEqual(twd.missingFx, [])
        XCTAssertEqual(twd.totalAssets, 940 + 210 * 32)
        XCTAssertEqual(twd.pnlExDiv, 40 + 10 * 32)
        let usd = book.overview(view: "USD").overview
        XCTAssertEqual(usd.totalAssets, (940 + 210 * 32) / 32)
    }

    func testFeeInOtherCurrencyNeedsRate() throws {
        let aapl = try book.upsertInstrument(market: Market.us, symbol: "AAPL", name: "Apple", assetType: "STOCK")
        let tx = TransactionRecord(portfolioId: portfolio.id, instrumentId: aapl.id, type: .buy, tradeDate: "2026-10-01",
                                   price: Dec(100), quantity: Dec(1), grossAmount: Dec(100), fee: Dec(30),
                                   costCurrency: "TWD", currency: "USD")
        XCTAssertThrowsError(try book.addTransaction(tx))
        var withRate = tx
        withRate.fxRateAtTrade = Dec(30)
        try book.addTransaction(withRate)
        try book.setManualFx(currency: "USD", value: 32, effectiveDate: "2026-10-01")
        XCTAssertEqual(book.overview(view: "USD").overview.historicalInvested, 101)
    }

    func testDeletePortfolioCascades() throws {
        try book.createPlan(monthlyPlan(), catchUp: true)
        try book.generatePending()
        try book.confirm(book.pendingOccurrences[0].id, ConfirmInput(tradeDate: "2026-09-30", price: 100, quantity: 30))
        try book.deletePortfolio(portfolio.id)
        XCTAssertTrue(book.data.plans.isEmpty)
        XCTAssertTrue(book.data.occurrences.isEmpty)
        XCTAssertTrue(book.data.transactions.isEmpty)
        XCTAssertEqual(book.data.instruments.count, 1)  // 標的與手動值屬於全域資料，保留
    }

    func testMonthlyPointsCoverFirstTradeToToday() throws {
        try book.addTransaction(TransactionRecord(portfolioId: portfolio.id, instrumentId: etf.id, type: .buy,
                                                  tradeDate: "2026-09-15", price: Dec(90), quantity: Dec(10),
                                                  grossAmount: Dec(900), currency: "TWD"))
        try book.applyQuotes([quote("0050", "94", "2026-11-17")])
        let pts = try book.monthlyPoints(view: "TWD")
        XCTAssertEqual(pts.map(\.month), ["2026-09", "2026-10", "2026-11"])
        XCTAssertTrue(pts[0].estimated)  // 9、10 月沒有月內價格，以成交價推估
        XCTAssertEqual(pts[2].marketValue, 940)
        XCTAssertFalse(pts[2].estimated)
    }
}
