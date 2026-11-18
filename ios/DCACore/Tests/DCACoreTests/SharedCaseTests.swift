import Foundation
import XCTest
@testable import DCACore

/// 執行 core/testcases/*.json 共用測試案例（與 core/python/tests/test_shared_cases.py 相同）。
final class SharedCaseTests: XCTestCase {
    // ios/DCACore/Tests/DCACoreTests/SharedCaseTests.swift → 倉庫根目錄
    static let casesDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // DCACoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // DCACore
        .deletingLastPathComponent() // ios
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("core/testcases")

    typealias J = [String: Any]

    func load(_ name: String) throws -> J {
        let data = try Data(contentsOf: Self.casesDir.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? J)
    }

    // MARK: - helpers

    func date(_ v: Any?) -> LocalDate? {
        guard let s = v as? String else { return nil }
        return LocalDate(iso: s)
    }

    func dec(_ v: Any?) -> Decimal? {
        guard let s = v as? String else { return nil }
        return Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
    }

    func q8(_ x: Decimal) -> Decimal {
        var input = x
        var out = Decimal()
        NSDecimalRound(&out, &input, 8, .bankers)
        return out
    }

    func assertDec(_ actual: Decimal?, _ expected: Any?, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let e = dec(expected) else {
            XCTAssertNil(actual, label, file: file, line: line)
            return
        }
        guard let a = actual else {
            XCTFail("\(label): nil != \(e)", file: file, line: line)
            return
        }
        XCTAssertEqual(q8(a), q8(e), "\(label): \(a) != \(e)", file: file, line: line)
    }

    func makeTx(_ t: J) throws -> Transaction {
        let typeRaw = try XCTUnwrap(t["type"] as? String)
        guard let type = TxType(rawValue: typeRaw) else { throw LedgerError("UNKNOWN_TYPE", typeRaw) }
        return Transaction(
            type: type,
            tradeDate: try XCTUnwrap(date(t["trade_date"])),
            currency: try XCTUnwrap(t["currency"] as? String),
            grossAmount: dec(t["gross_amount"]) ?? 0,
            price: dec(t["price"]),
            quantity: dec(t["quantity"]),
            fee: dec(t["fee"]) ?? 0,
            tax: dec(t["tax"]) ?? 0,
            otherCost: dec(t["other_cost"]) ?? 0,
            costCurrency: t["cost_currency"] as? String,
            fxRateAtTrade: dec(t["fx_rate_at_trade"]),
            seq: (t["seq"] as? Int) ?? 0
        )
    }

    func makeOverrides(_ v: Any?) -> [Override] {
        guard let list = v as? [J] else { return [] }
        return list.map {
            Override(value: dec($0["value"])!, effectiveDate: date($0["effective_date"])!,
                     setAt: $0["set_at"] as! String, active: ($0["active"] as? Bool) ?? true)
        }
    }

    func makePriceInput(_ v: Any?) -> PriceInput? {
        guard let p = v as? J else { return nil }
        return PriceInput(overrides: makeOverrides(p["overrides"]), autoValue: dec(p["auto_value"]),
                          autoDataDate: date(p["auto_data_date"]))
    }

    struct OccRow: Equatable, CustomStringConvertible {
        var periodKey: String
        var nominal: String
        var scheduled: String
        var reasons: [String]
        var merged: [String]
        var description: String { "\(periodKey) \(nominal)->\(scheduled) \(reasons) \(merged)" }
    }

    func occRow(_ o: Occurrence) -> OccRow {
        OccRow(periodKey: o.periodKey, nominal: o.nominalDate.iso, scheduled: o.scheduledDate.iso,
               reasons: o.adjustReasons, merged: o.mergedKeys)
    }

    func occRow(_ j: J) -> OccRow {
        OccRow(periodKey: j["period_key"] as? String ?? "", nominal: j["nominal_date"] as? String ?? "",
               scheduled: j["scheduled_date"] as? String ?? "",
               reasons: j["adjust_reasons"] as? [String] ?? [], merged: j["merged_keys"] as? [String] ?? [])
    }

    // MARK: - schedule

    func makeCalendar(_ root: J, _ name: String) throws -> TradingCalendar {
        let cals = try XCTUnwrap(root["calendars"] as? J)
        let c = try XCTUnwrap(cals[name] as? J)
        let hs = (c["holidays"] as? [String] ?? []).compactMap { LocalDate(iso: $0) }
        return TradingCalendar(holidays: Set(hs), knownThrough: date(c["known_through"]))
    }

    func makePlan(_ p: J) throws -> Plan {
        try Plan(
            frequency: try XCTUnwrap(Frequency(rawValue: p["frequency"] as? String ?? "")),
            startDate: try XCTUnwrap(date(p["start_date"])),
            endDate: date(p["end_date"]),
            weekdays: p["weekdays"] as? [Int] ?? [],
            monthDays: p["month_days"] as? [Int] ?? [],
            specificDates: (p["specific_dates"] as? [String] ?? []).compactMap { LocalDate(iso: $0) },
            holidayRule: HolidayRule(rawValue: p["holiday_rule"] as? String ?? "NEXT_TRADING_DAY") ?? .nextTradingDay,
            paused: p["paused"] as? Bool ?? false
        )
    }

    func testScheduleDue() throws {
        let root = try load("schedule_cases.json")
        for c in try XCTUnwrap(root["due_cases"] as? [J]) {
            let id = c["id"] as! String
            let got = try dueOccurrences(
                plan: makePlan(c["plan"] as! J),
                calendar: makeCalendar(root, c["calendar"] as! String),
                today: date(c["today"])!,
                existingKeys: Set(c["existing_keys"] as? [String] ?? []),
                since: date(c["since"])
            )
            let expect: [OccRow] = (c["expect"] as! [J]).map { occRow($0) }
            XCTAssertEqual(got.map { occRow($0) }, expect, id)
        }
    }

    func testScheduleUpcoming() throws {
        let root = try load("schedule_cases.json")
        for c in try XCTUnwrap(root["upcoming_cases"] as? [J]) {
            let got = try upcomingOccurrences(
                plan: makePlan(c["plan"] as! J),
                calendar: makeCalendar(root, c["calendar"] as! String),
                today: date(c["today"])!,
                count: c["count"] as! Int
            )
            let expect: [OccRow] = (c["expect"] as! [J]).map { occRow($0) }
            XCTAssertEqual(got.map { occRow($0) }, expect, c["id"] as! String)
        }
    }

    func testMarketToday() throws {
        let root = try load("schedule_cases.json")
        let fmt = ISO8601DateFormatter()
        for c in try XCTUnwrap(root["market_today_cases"] as? [J]) {
            let now = try XCTUnwrap(fmt.date(from: c["now_utc"] as! String))
            let got = try marketToday(market: c["market"] as! String, now: now)
            XCTAssertEqual(got.iso, c["expect"] as? String, c["id"] as! String)
        }
    }

    // MARK: - ledger

    func testLedger() throws {
        let root = try load("ledger_cases.json")
        for c in try XCTUnwrap(root["cases"] as? [J]) {
            let id = c["id"] as! String
            let txs = try (c["transactions"] as! [J]).map(makeTx)
            if let code = c["expect_error"] as? String {
                XCTAssertThrowsError(try buildPosition(txs, asOf: date(c["as_of"])), id) { err in
                    XCTAssertEqual((err as? LedgerError)?.code, code, id)
                }
                continue
            }
            let p = try buildPosition(txs, asOf: date(c["as_of"]))
            let e = c["expect"] as! J
            assertDec(p.quantity, e["quantity"], "\(id).quantity")
            assertDec(p.costBasis, e["cost_basis"], "\(id).cost_basis")
            assertDec(p.reinvestedCost, e["reinvested_cost"], "\(id).reinvested_cost")
            assertDec(p.historicalInvested, e["historical_invested"], "\(id).historical_invested")
            assertDec(p.realizedPnl, e["realized_pnl"], "\(id).realized_pnl")
            assertDec(p.dividendsNet, e["dividends_net"], "\(id).dividends_net")
            assertDec(p.standaloneFees, e["standalone_fees"], "\(id).standalone_fees")
            assertDec(p.lastTradePrice, e["last_trade_price"], "\(id).last_trade_price")
            assertDec(p.investedCurrent, e["invested_current"], "\(id).invested_current")
            assertDec(p.avgCost, e["avg_cost"], "\(id).avg_cost")
        }
    }

    // MARK: - valuation

    func testOverview() throws {
        let root = try load("valuation_cases.json")
        let asOf = date(root["as_of"])!
        let holdings = try (root["holdings"] as! [J]).map { h in
            Holding(portfolioId: h["portfolio_id"] as! String, instrumentId: h["instrument_id"] as! String,
                    currency: h["currency"] as! String,
                    position: try buildPosition((h["transactions"] as! [J]).map(makeTx)),
                    includeInOverview: h["include_in_overview"] as? Bool ?? true)
        }
        var prices: [String: PriceInput] = [:]
        for (k, v) in root["prices"] as! J { prices[k] = makePriceInput(v) }
        for c in try XCTUnwrap(root["overview_cases"] as? [J]) {
            let id = c["id"] as! String
            let drop = Set(c["drop_fx"] as? [String] ?? [])
            var fx: [String: FxInput] = [:]
            for (k, v) in root["fx"] as! J where !drop.contains(k) { fx[k] = makePriceInput(v) }
            let ov = overview(holdings: holdings, prices: prices, fx: fx, view: c["view"] as! String, asOf: asOf)
            let e = c["expect"] as! J
            assertDec(ov.totalAssets, e["total_assets"], "\(id).total_assets")
            assertDec(ov.investedCurrent, e["invested_current"], "\(id).invested_current")
            assertDec(ov.historicalInvested, e["historical_invested"], "\(id).historical_invested")
            assertDec(ov.pnlExDiv, e["pnl_ex_div"], "\(id).pnl_ex_div")
            assertDec(ov.pnlIncDiv, e["pnl_inc_div"], "\(id).pnl_inc_div")
            assertDec(ov.returnExDiv, e["return_ex_div"], "\(id).return_ex_div")
            assertDec(ov.returnIncDiv, e["return_inc_div"], "\(id).return_inc_div")
            XCTAssertEqual(ov.missingFx, e["missing_fx"] as? [String], id)
            XCTAssertEqual(ov.estimatedInstruments, e["estimated_instruments"] as? [String], id)
            let rows = Dictionary(uniqueKeysWithValues: ov.rows.map { ($0.instrumentId, $0) })
            for (iid, erAny) in (e["rows"] as? J ?? [:]) {
                let er = erAny as! J
                let r = try XCTUnwrap(rows[iid], "\(id).\(iid)")
                assertDec(r.quantity, er["quantity"], "\(id).\(iid).quantity")
                assertDec(r.avgCost, er["avg_cost"], "\(id).\(iid).avg_cost")
                assertDec(r.price, er["price"], "\(id).\(iid).price")
                XCTAssertEqual(r.priceSource.rawValue, er["price_source"] as? String, "\(id).\(iid)")
            }
        }
    }

    func testResolvePrice() throws {
        let root = try load("valuation_cases.json")
        for c in try XCTUnwrap(root["resolve_price_cases"] as? [J]) {
            let id = c["id"] as! String
            let (v, src) = resolvePrice(makePriceInput(c["input"]), asOf: date(c["as_of"])!,
                                        lastTradePrice: dec(c["last_trade_price"]))
            let e = c["expect"] as! J
            assertDec(v, e["value"], "\(id).value")
            XCTAssertEqual(src.rawValue, e["source"] as? String, id)
        }
    }

    // MARK: - snapshots

    func makeSeries(_ v: Any?) -> Series {
        guard let s = v as? J else { return Series() }
        let pts = (s["points"] as? [[String]] ?? []).map { (LocalDate(iso: $0[0])!, dec($0[1])!) }
        return Series(points: pts, overrides: makeOverrides(s["overrides"]))
    }

    func testSnapshots() throws {
        let root = try load("snapshot_cases.json")
        for c in try XCTUnwrap(root["cases"] as? [J]) {
            let id = c["id"] as! String
            let hs = try (c["holdings"] as! [J]).map { h in
                SnapshotHolding(instrumentId: h["instrument_id"] as! String, currency: h["currency"] as! String,
                                transactions: try (h["transactions"] as! [J]).map(makeTx))
            }
            var ph: [String: Series] = [:]
            for (k, v) in c["price_history"] as? J ?? [:] { ph[k] = makeSeries(v) }
            var fh: [String: Series] = [:]
            for (k, v) in c["fx_history"] as? J ?? [:] { fh[k] = makeSeries(v) }
            let pts = try monthlySnapshots(holdings: hs, priceHistory: ph, fxHistory: fh,
                                           view: c["view"] as! String, asOf: date(c["as_of"])!,
                                           onlyCurrency: c["only_currency"] as? String)
            let expect = c["expect"] as! [J]
            XCTAssertEqual(pts.count, expect.count, id)
            for (p, e) in zip(pts, expect) {
                let m = e["month"] as! String
                XCTAssertEqual(p.month, m, id)
                XCTAssertEqual(p.date.iso, e["date"] as? String, "\(id).\(m)")
                assertDec(p.marketValue, e["market_value"], "\(id).\(m).market_value")
                assertDec(p.investedCurrent, e["invested_current"], "\(id).\(m).invested_current")
                assertDec(p.historicalInvested, e["historical_invested"], "\(id).\(m).historical_invested")
                assertDec(p.pnlExDiv, e["pnl_ex_div"], "\(id).\(m).pnl_ex_div")
                assertDec(p.pnlIncDiv, e["pnl_inc_div"], "\(id).\(m).pnl_inc_div")
                XCTAssertEqual(p.estimated, e["estimated"] as? Bool, "\(id).\(m).estimated")
                XCTAssertEqual(p.estimatedItems, e["estimated_items"] as? [String], "\(id).\(m).estimated_items")
                XCTAssertEqual(p.missingFx, e["missing_fx"] as? [String], "\(id).\(m).missing_fx")
            }
        }
    }
}

/// 不依賴共用 JSON 的日期運算檢查。
final class LocalDateTests: XCTestCase {
    func testEpochRoundTrip() {
        for z in stride(from: -800_000, through: 800_000, by: 997) {
            XCTAssertEqual(LocalDate(daysSinceEpoch: z).daysSinceEpoch, z)
        }
        XCTAssertEqual(LocalDate(1970, 1, 1).daysSinceEpoch, 0)
        XCTAssertEqual(LocalDate(1970, 1, 1).isoWeekday, 4)
    }

    func testIsoWeek() {
        XCTAssertTrue(LocalDate(2027, 1, 1).isoYearWeek == (2026, 53))
        XCTAssertTrue(LocalDate(2027, 1, 4).isoYearWeek == (2027, 1))
        XCTAssertTrue(LocalDate(2026, 10, 5).isoYearWeek == (2026, 41))
    }

    func testMonthLengths() {
        XCTAssertEqual(LocalDate.daysInMonth(year: 2028, month: 2), 29)
        XCTAssertEqual(LocalDate.daysInMonth(year: 2100, month: 2), 28)
        XCTAssertEqual(LocalDate.daysInMonth(year: 2000, month: 2), 29)
        XCTAssertNil(LocalDate(iso: "2027-02-29"))
    }
}
