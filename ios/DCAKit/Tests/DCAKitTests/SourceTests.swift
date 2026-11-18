import DCACore
import Foundation
import XCTest
@testable import DCAKit

final class FakeTransport: HTTPTransport {
    var responses: [String: (Data, Int)] = [:]
    var failures: Set<String> = []
    private(set) var calls: [(url: String, headers: [String: String])] = []

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        calls.append((url.absoluteString, headers))
        if failures.contains(url.absoluteString) { throw URLError(.notConnectedToInternet) }
        let key = url.absoluteString
        return responses[key] ?? responses[key.removingPercentEncoding ?? key] ?? (Data(), 404)
    }
}

func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func officialTransport() throws -> FakeTransport {
    let t = FakeTransport()
    t.responses[DirectTaiwanOpenAPISource.twseURL.absoluteString] = (try fixture("twse_stock_day_all"), 200)
    t.responses[DirectTaiwanOpenAPISource.tpexURL.absoluteString] = (try fixture("tpex_mainboard_quotes"), 200)
    return t
}

final class SourceTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(TaiwanParsing.rocDate("1151118")?.iso, "2026-11-18")
        XCTAssertNil(TaiwanParsing.rocDate("1150230"))
        XCTAssertEqual(TaiwanParsing.decimal("2,170.00"), D("2170"))
        XCTAssertEqual(TaiwanParsing.decimal("-0.5100"), D("-0.51"))
        for empty in ["", "----", "---", " -- ", "N/A"] { XCTAssertNil(TaiwanParsing.decimal(empty), empty) }
        XCTAssertEqual(TaiwanParsing.normKeys(["主旨 ": "x", " A b": "y", "n": 1]), ["主旨": "x", "Ab": "y"])
    }

    func testDirectListingUsesRealOfficialResponses() async throws {
        let src = DirectTaiwanOpenAPISource(transport: try officialTransport())
        let listing = try await src.fetchListing()
        let by = Dictionary(uniqueKeysWithValues: listing.map { ($0.symbol, $0) })
        XCTAssertEqual(by["2330"]?.close, D("2170"))
        XCTAssertEqual(by["2330"]?.board, "TWSE")
        XCTAssertEqual(by["2330"]?.dataDate?.iso, "2026-11-17")
        XCTAssertEqual(by["6488"]?.board, "TPEX")
        XCTAssertNil(by["00734B"]?.close)  // 當日未成交 "----"
        XCTAssertNil(by["00625K"]?.close)  // TWSE 空字串
        let snaps = DirectTaiwanOpenAPISource.snapshots(from: listing, symbols: ["2330", "6488", "00734B", "9999"])
        XCTAssertEqual(snaps.map(\.symbol).sorted(), ["2330", "6488"])
        XCTAssertTrue(snaps.first { $0.symbol == "6488" }!.attribution.contains("證券櫃檯買賣中心"))
    }

    func testDirectSourceHTTPError() async {
        let t = FakeTransport()
        do {
            _ = try await DirectTaiwanOpenAPISource(transport: t).fetchListing()
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? QuoteSourceError, .http(404))
        }
    }

    func testBackendSourceDecodesStringDecimals() async throws {
        let t = FakeTransport()
        let body = #"{"quotes":[{"symbol":"TW:6488","name":"環球晶","board":"TPEX","asset_type":"STOCK","currency":"TWD","close":"544.00","change":"1","data_date":"2026-11-18","fetched_at":"x","source_id":"TPEX_MAINBOARD_QUOTES","source_url":"https://www.tpex.org.tw/openapi/v1/tpex_mainboard_quotes","attribution":"資料來源：證券櫃檯買賣中心"}],"missing":["TW:9999"]}"#
        t.responses["https://api.example.invalid/v1/quotes?symbols=TW:6488,TW:9999"] = (Data(body.utf8), 200)
        let src = BackendQuoteSource(baseURL: URL(string: "https://api.example.invalid")!, transport: t)
        let q = try await src.fetch(twSymbols: ["6488", "9999"])
        XCTAssertEqual(q.map(\.symbol), ["6488"])
        XCTAssertEqual(q[0].close, D("544"))
        XCTAssertEqual(q[0].dataDate.iso, "2026-11-18")
    }

    func testFinnhubKeyIsSentInHeaderNotURL() async {
        let t = FakeTransport()
        t.responses["https://finnhub.io/api/v1/quote?symbol=AAPL"] = (Data(#"{"c":210.5,"t":1794949200,"pc":209}"#.utf8), 200)
        t.responses["https://finnhub.io/api/v1/quote?symbol=ZZZZ"] = (Data(#"{"c":0,"t":0}"#.utf8), 200)
        let r = await FinnhubQuoteSource(apiKey: "secret-key", transport: t).fetch(usSymbols: ["AAPL", "ZZZZ"])
        XCTAssertEqual(r.quotes.map(\.symbol), ["AAPL"])
        XCTAssertEqual(r.quotes[0].close, D("210.5"))
        XCTAssertEqual(r.quotes[0].dataDate.iso, "2026-11-17")  // 1794949200 = 2026-11-17 16:00 美東
        XCTAssertEqual(r.errors, ["US:ZZZZ 無資料"])
        XCTAssertTrue(t.calls.allSatisfy { !$0.url.contains("secret") && $0.headers["X-Finnhub-Token"] == "secret-key" })
    }
}

final class RefreshTests: XCTestCase {
    func testDirectRefreshThrottleAndOverrideSafety() async throws {
        var clock = WED_4PM
        let book = try PortfolioBook(store: InMemoryDataStore(), now: { clock })
        let inst = try book.upsertInstrument(market: Market.tw, symbol: "2330", name: "台積電", assetType: "STOCK")
        try book.setManualPrice(instrumentId: inst.id, value: 2000, effectiveDate: "2026-11-01")
        let t = try officialTransport()
        let rc = RefreshCoordinator(book: book, direct: DirectTaiwanOpenAPISource(transport: t), now: { clock })

        let r1 = await rc.refresh()
        XCTAssertEqual(r1.updated, 1)
        XCTAssertEqual(r1.errors, [])
        XCTAssertEqual(t.calls.count, 2)
        XCTAssertEqual(book.data.priceCache[inst.id.uuidString]?.value.value, D("2170"))
        XCTAssertEqual(book.currentPrice(inst).0, 2000)  // 手動值不受影響

        clock = clock.addingTimeInterval(3600)
        let r2 = await rc.refresh()
        XCTAssertEqual(r2.skippedSources, [RefreshCoordinator.twKey])
        XCTAssertEqual(t.calls.count, 2)

        _ = await rc.refresh(force: true)
        XCTAssertEqual(t.calls.count, 4)
    }

    func testFailureKeepsCacheAndReportsError() async throws {
        let book = try PortfolioBook(store: InMemoryDataStore(), now: { WED_4PM })
        let inst = try book.upsertInstrument(market: Market.tw, symbol: "2330", name: "台積電", assetType: "STOCK")
        try book.applyQuotes([QuoteSnapshot(market: "TW", symbol: "2330", close: 2100, dataDate: LocalDate(2026, 11, 16),
                                            sourceId: "x", sourceURL: "x", attribution: "x")])
        let t = FakeTransport()
        t.failures = [DirectTaiwanOpenAPISource.twseURL.absoluteString]
        let r = await RefreshCoordinator(book: book, direct: DirectTaiwanOpenAPISource(transport: t), now: { WED_4PM }).refresh()
        XCTAssertEqual(r.errors.count, 1)
        XCTAssertTrue(r.errors[0].hasPrefix("台股行情"))
        XCTAssertEqual(book.currentPrice(inst).0, 2100)
        XCTAssertNil(book.data.lastRefresh[RefreshCoordinator.twKey])
    }
}
