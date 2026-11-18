import DCACore
import Foundation

public enum BookError: Error, Equatable {
    case invalidName(String)
    case duplicateName
    case notFound
    case invalidPlan(String)
    case invalidDate(String)
    case invalidAmount(String)
    case ledger(String)
    case occurrenceNotPending
}

/// 待確認期別的合計（首頁定期定額卡）。
public struct PendingSummary: Equatable {
    public var count: Int
    /// 以檢視幣別估算；缺匯率的期別不計入，另列在 unconvertible
    public var estimatedTotal: Decimal
    public var unconvertibleCount: Int
}

public struct OverviewResult {
    public var overview: Overview
    public var pending: PendingSummary
    /// 交易資料無法回放的部位（理論上不會發生：寫入前已驗證）
    public var brokenHoldings: [String]
}

/// 確認待確認期別時使用者填入的實際成交資料。
public struct ConfirmInput {
    public var tradeDate: String
    public var price: Decimal
    public var quantity: Decimal
    public var grossAmount: Decimal?
    public var fee: Decimal
    public var tax: Decimal
    public var otherCost: Decimal
    public var costCurrency: String?
    public var fxRateAtTrade: Decimal?

    public init(tradeDate: String, price: Decimal, quantity: Decimal, grossAmount: Decimal? = nil, fee: Decimal = 0,
                tax: Decimal = 0, otherCost: Decimal = 0, costCurrency: String? = nil, fxRateAtTrade: Decimal? = nil) {
        self.tradeDate = tradeDate
        self.price = price
        self.quantity = quantity
        self.grossAmount = grossAmount
        self.fee = fee
        self.tax = tax
        self.otherCost = otherCost
        self.costCurrency = costCurrency
        self.fxRateAtTrade = fxRateAtTrade
    }
}

/// 一筆自動取得的報價或匯率。
public struct QuoteSnapshot: Equatable {
    public var market: String
    public var symbol: String
    public var name: String?
    public var close: Decimal
    public var dataDate: LocalDate
    public var sourceId: String
    public var sourceURL: String
    public var attribution: String

    public init(market: String, symbol: String, name: String? = nil, close: Decimal, dataDate: LocalDate,
                sourceId: String, sourceURL: String, attribution: String) {
        self.market = market
        self.symbol = symbol
        self.name = name
        self.close = close
        self.dataDate = dataDate
        self.sourceId = sourceId
        self.sourceURL = sourceURL
        self.attribution = attribution
    }
}

/// 本機投資資料的唯一入口：所有修改都先驗證、再寫入 DataStore。
/// 計算一律交給 DCACore（與後端 Python 參考實作共用測試案例）。
public final class PortfolioBook {
    public private(set) var data: AppData
    private let store: DataStore
    private let now: () -> Date

    public init(store: DataStore, now: @escaping () -> Date = Date.init) throws {
        self.store = store
        self.now = now
        self.data = try store.load()
    }

    private func commit(_ newData: AppData) throws {
        try store.save(newData)
        data = newData
    }

    public func today(market: String) -> LocalDate {
        (try? marketToday(market: Market.calendarKey(market), now: now())) ?? LocalDate(daysSinceEpoch: 0)
    }

    // MARK: - 投資組合（docs/02 §1）

    public var activePortfolios: [Portfolio] {
        data.portfolios.filter { $0.archivedAt == nil }.sorted { $0.sortOrder < $1.sortOrder }
    }

    private static func cleanName(_ name: String) throws -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...20).contains(n.count) else { throw BookError.invalidName("名稱需為 1～20 字") }
        return n
    }

    @discardableResult
    public func createPortfolio(name: String, note: String? = nil, colorHex: String = "#3B82F6",
                                defaultCurrency: String = "TWD", includeInOverview: Bool = true) throws -> Portfolio {
        let n = try Self.cleanName(name)
        guard !data.portfolios.contains(where: { $0.name == n }) else { throw BookError.duplicateName }
        let t = now()
        let p = Portfolio(id: UUID(), name: n, note: note, colorHex: colorHex, defaultCurrency: defaultCurrency,
                          includeInOverview: includeInOverview,
                          sortOrder: (data.portfolios.map(\.sortOrder).max() ?? -1) + 1,
                          archivedAt: nil, createdAt: t, updatedAt: t)
        var d = data
        d.portfolios.append(p)
        try commit(d)
        return p
    }

    public func updatePortfolio(_ p: Portfolio) throws {
        var updated = p
        updated.name = try Self.cleanName(p.name)
        guard let i = data.portfolios.firstIndex(where: { $0.id == p.id }) else { throw BookError.notFound }
        guard !data.portfolios.contains(where: { $0.id != p.id && $0.name == updated.name }) else { throw BookError.duplicateName }
        updated.updatedAt = now()
        var d = data
        d.portfolios[i] = updated
        try commit(d)
    }

    public func setArchived(_ id: UUID, _ archived: Bool) throws {
        guard let i = data.portfolios.firstIndex(where: { $0.id == id }) else { throw BookError.notFound }
        var d = data
        d.portfolios[i].archivedAt = archived ? now() : nil
        d.portfolios[i].updatedAt = now()
        try commit(d)
    }

    /// 刪除組合及其計畫、期別、交易（UI 需先要求輸入 App 密碼）。
    public func deletePortfolio(_ id: UUID) throws {
        guard data.portfolios.contains(where: { $0.id == id }) else { throw BookError.notFound }
        var d = data
        let planIds = Set(d.plans.filter { $0.portfolioId == id }.map(\.id))
        d.portfolios.removeAll { $0.id == id }
        d.plans.removeAll { $0.portfolioId == id }
        d.occurrences.removeAll { planIds.contains($0.planId) }
        d.transactions.removeAll { $0.portfolioId == id }
        try commit(d)
    }

    // MARK: - 標的

    @discardableResult
    public func upsertInstrument(market: String, symbol: String, name: String, assetType: String,
                                 currency: String? = nil, board: String? = nil, isUserDefined: Bool = false) throws -> Instrument {
        let sym = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !sym.isEmpty else { throw BookError.invalidName("代號不可空白") }
        var d = data
        if let i = d.instruments.firstIndex(where: { $0.market == market && $0.symbol == sym }) {
            d.instruments[i].name = name
            if let b = board { d.instruments[i].board = b }
            try commit(d)
            return d.instruments[i]
        }
        let inst = Instrument(id: UUID(), market: market, board: board, symbol: sym, name: name, assetType: assetType,
                              currency: currency ?? Market.currency(market), isUserDefined: isUserDefined)
        d.instruments.append(inst)
        try commit(d)
        return inst
    }

    public func instrument(_ id: UUID) -> Instrument? { data.instruments.first { $0.id == id } }

    // MARK: - 定期定額計畫（docs/02 §3）

    private func calendar(for market: String) -> TradingCalendar {
        let key = Market.calendarKey(market)
        let hs = Set((data.holidays[key] ?? []).compactMap { LocalDate(iso: $0) })
        // 沒有休市表時：只排除週末，並讓所有日期標示「日曆未更新」
        let known = data.holidaysKnownThrough[key].flatMap { LocalDate(iso: $0) } ?? LocalDate(1970, 1, 1)
        return TradingCalendar(holidays: hs, knownThrough: known)
    }

    /// 新增計畫。開始日早於今天時，`catchUp` 決定是否補產生過去的期數（docs/02 §3.3）。
    @discardableResult
    public func createPlan(_ plan: PlanRecord, catchUp: Bool) throws -> PlanRecord {
        guard data.portfolios.contains(where: { $0.id == plan.portfolioId }) else { throw BookError.notFound }
        guard let inst = instrument(plan.instrumentId) else { throw BookError.notFound }
        guard plan.amount.value > 0 else { throw BookError.invalidAmount("每期金額或數量需大於 0") }
        let core = try plan.corePlan()
        var p = plan
        let today = self.today(market: inst.market)
        p.generateFrom = (catchUp || core.startDate > today) ? plan.startDate : today.iso
        var d = data
        d.plans.append(p)
        try commit(d)
        return p
    }

    public func updatePlan(_ plan: PlanRecord) throws {
        guard let i = data.plans.firstIndex(where: { $0.id == plan.id }) else { throw BookError.notFound }
        guard plan.amount.value > 0 else { throw BookError.invalidAmount("每期金額或數量需大於 0") }
        _ = try plan.corePlan()
        var d = data
        d.plans[i] = plan
        try commit(d)
    }

    /// 刪除計畫：移除尚未確認的期別；已確認的交易保留。
    public func deletePlan(_ id: UUID) throws {
        guard data.plans.contains(where: { $0.id == id }) else { throw BookError.notFound }
        var d = data
        d.plans.removeAll { $0.id == id }
        d.occurrences.removeAll { $0.planId == id && $0.status == .pending }
        try commit(d)
    }

    public func previewUpcoming(_ plan: PlanRecord, count: Int = 6) throws -> [Occurrence] {
        guard let inst = instrument(plan.instrumentId) else { throw BookError.notFound }
        return try upcomingOccurrences(plan: plan.corePlan(), calendar: calendar(for: inst.market),
                                       today: today(market: inst.market), count: count)
    }

    /// 開啟 App 時呼叫：補產生所有到期但尚未存在的期別（狀態「待確認」）。重複呼叫不會重複產生。
    @discardableResult
    public func generatePending() throws -> [OccurrenceRecord] {
        var d = data
        var created: [OccurrenceRecord] = []
        for plan in d.plans where !plan.paused {
            guard let inst = instrument(plan.instrumentId) else { continue }
            let existing = Set(d.occurrences.filter { $0.planId == plan.id }.map(\.periodKey))
            let due = try dueOccurrences(plan: plan.corePlan(), calendar: calendar(for: inst.market),
                                         today: today(market: inst.market), existingKeys: existing,
                                         since: LocalDate(iso: plan.generateFrom))
            let (price, _) = currentPrice(inst)
            for o in due {
                var rec = OccurrenceRecord(id: UUID(), planId: plan.id, periodKey: o.periodKey,
                                           nominalDate: o.nominalDate.iso, scheduledDate: o.scheduledDate.iso,
                                           adjustReasons: o.adjustReasons, mergedKeys: o.mergedKeys,
                                           calendarUnknown: o.calendarUnknown, status: .pending,
                                           estPrice: price.map { Dec($0) }, estQuantity: nil, estAmount: nil,
                                           transactionId: nil)
                switch plan.amountMode {
                case .amount:
                    rec.estAmount = plan.amount
                    if let p = price, p > 0 { rec.estQuantity = Dec(plan.amount.value / p) }
                case .quantity:
                    rec.estQuantity = plan.amount
                    if let p = price { rec.estAmount = Dec(plan.amount.value * p) }
                }
                created.append(rec)
            }
        }
        guard !created.isEmpty else { return [] }
        d.occurrences.append(contentsOf: created)
        try commit(d)
        return created
    }

    public var pendingOccurrences: [OccurrenceRecord] {
        data.occurrences.filter { $0.status == .pending }.sorted { ($0.scheduledDate, $0.periodKey) < ($1.scheduledDate, $1.periodKey) }
    }

    /// 確認：補上實際成交資料，產生買入交易；之後才計入資產。
    @discardableResult
    public func confirm(_ occurrenceId: UUID, _ input: ConfirmInput) throws -> TransactionRecord {
        guard let oi = data.occurrences.firstIndex(where: { $0.id == occurrenceId }) else { throw BookError.notFound }
        guard data.occurrences[oi].status == .pending else { throw BookError.occurrenceNotPending }
        guard let plan = data.plans.first(where: { $0.id == data.occurrences[oi].planId }),
              let inst = instrument(plan.instrumentId) else { throw BookError.notFound }
        guard input.price > 0, input.quantity > 0 else { throw BookError.invalidAmount("價格與數量需大於 0") }
        let gross = input.grossAmount ?? input.price * input.quantity
        let tx = TransactionRecord(portfolioId: plan.portfolioId, instrumentId: inst.id, type: .buy,
                                   tradeDate: input.tradeDate, price: Dec(input.price), quantity: Dec(input.quantity),
                                   grossAmount: Dec(gross), fee: Dec(input.fee), tax: Dec(input.tax),
                                   otherCost: Dec(input.otherCost), costCurrency: input.costCurrency,
                                   currency: inst.currency, fxRateAtTrade: input.fxRateAtTrade.map { Dec($0) },
                                   occurrenceId: occurrenceId, createdAt: now(), updatedAt: now())
        var d = try dataByAdding(tx, to: data)
        d.occurrences[oi].status = .confirmed
        d.occurrences[oi].transactionId = d.transactions.last?.id
        try commit(d)
        return d.transactions.last!
    }

    /// 略過：該期沒有扣款。
    public func skip(_ occurrenceId: UUID) throws {
        guard let oi = data.occurrences.firstIndex(where: { $0.id == occurrenceId }) else { throw BookError.notFound }
        guard data.occurrences[oi].status == .pending else { throw BookError.occurrenceNotPending }
        var d = data
        d.occurrences[oi].status = .skipped
        try commit(d)
    }

    // MARK: - 交易紀錄

    /// 寫入前回放該部位所有交易，確保不會出現賣超等不合法狀態。
    private func dataByAdding(_ tx: TransactionRecord, to base: AppData) throws -> AppData {
        try requireFeeRate(tx, in: base)
        var d = base
        var t = tx
        t.seq = d.nextSeq
        d.nextSeq += 1
        d.transactions.append(t)
        try validatePosition(portfolioId: t.portfolioId, instrumentId: t.instrumentId, in: d)
        return d
    }

    /// 費用幣別與標的不同時，需要交易日匯率或目前匯率，否則拒絕（避免費用被當成 0）。
    private func requireFeeRate(_ tx: TransactionRecord, in d: AppData) throws {
        guard let cc = tx.costCurrency, cc != tx.currency else { return }
        let costs = tx.fee.value + tx.tax.value + tx.otherCost.value
        guard costs != 0 else { return }
        if let r = tx.fxRateAtTrade?.value, r > 0, cc == "TWD" || tx.currency == "TWD" { return }
        if convert(1, from: cc, to: tx.currency, rates: currentRates(d)) == nil {
            throw BookError.invalidAmount("費用幣別與標的不同，請填入交易日匯率")
        }
    }

    private func validatePosition(portfolioId: UUID, instrumentId: UUID, in d: AppData) throws {
        let txs = try d.transactions.filter { $0.portfolioId == portfolioId && $0.instrumentId == instrumentId }
            .map { try $0.coreTransaction() }
        do {
            _ = try buildPosition(txs, fxFallback: fxFallback(d))
        } catch let e as LedgerError {
            throw BookError.ledger(e.code)
        }
    }

    @discardableResult
    public func addTransaction(_ tx: TransactionRecord) throws -> TransactionRecord {
        guard data.portfolios.contains(where: { $0.id == tx.portfolioId }), instrument(tx.instrumentId) != nil else {
            throw BookError.notFound
        }
        guard LocalDate(iso: tx.tradeDate) != nil else { throw BookError.invalidDate(tx.tradeDate) }
        var t = tx
        t.createdAt = now()
        t.updatedAt = now()
        let d = try dataByAdding(t, to: data)
        try commit(d)
        return d.transactions.last!
    }

    public func updateTransaction(_ tx: TransactionRecord) throws {
        guard let i = data.transactions.firstIndex(where: { $0.id == tx.id }) else { throw BookError.notFound }
        guard LocalDate(iso: tx.tradeDate) != nil else { throw BookError.invalidDate(tx.tradeDate) }
        try requireFeeRate(tx, in: data)
        var d = data
        var t = tx
        t.seq = d.transactions[i].seq
        t.updatedAt = now()
        d.transactions[i] = t
        try validatePosition(portfolioId: t.portfolioId, instrumentId: t.instrumentId, in: d)
        try commit(d)
    }

    /// 刪除交易；若由定期定額確認而來，該期別回到「待確認」。
    public func deleteTransaction(_ id: UUID) throws {
        guard let tx = data.transactions.first(where: { $0.id == id }) else { throw BookError.notFound }
        var d = data
        d.transactions.removeAll { $0.id == id }
        try validatePosition(portfolioId: tx.portfolioId, instrumentId: tx.instrumentId, in: d)
        if let oid = tx.occurrenceId, let oi = d.occurrences.firstIndex(where: { $0.id == oid }) {
            d.occurrences[oi].status = .pending
            d.occurrences[oi].transactionId = nil
        }
        try commit(d)
    }

    public func transactions(portfolioId: UUID? = nil, instrumentId: UUID? = nil) -> [TransactionRecord] {
        data.transactions
            .filter { (portfolioId == nil || $0.portfolioId == portfolioId) && (instrumentId == nil || $0.instrumentId == instrumentId) }
            .sorted { ($0.tradeDate, $0.seq) > ($1.tradeDate, $1.seq) }
    }

    // MARK: - 手動價格、淨值、匯率（docs/05 §3）

    public static func fxKey(_ currency: String) -> String { "FX:\(currency)" }

    private func addOverride(key: String, value: Decimal, effectiveDate: String, note: String?) throws {
        guard value > 0 else { throw BookError.invalidAmount("數值需大於 0") }
        guard LocalDate(iso: effectiveDate) != nil else { throw BookError.invalidDate(effectiveDate) }
        var d = data
        d.overrides.append(OverrideRecord(id: UUID(), key: key, value: Dec(value), effectiveDate: effectiveDate,
                                          setAt: now(), active: true, note: note))
        try commit(d)
    }

    public func setManualPrice(instrumentId: UUID, value: Decimal, effectiveDate: String, note: String? = nil) throws {
        guard instrument(instrumentId) != nil else { throw BookError.notFound }
        try addOverride(key: instrumentId.uuidString, value: value, effectiveDate: effectiveDate, note: note)
    }

    public func setManualFx(currency: String, value: Decimal, effectiveDate: String, note: String? = nil) throws {
        try addOverride(key: Self.fxKey(currency), value: value, effectiveDate: effectiveDate, note: note)
    }

    /// 只有使用者按「改回自動」才會停用手動值；自動更新永遠不會。
    public func revertToAuto(key: String) throws {
        var d = data
        for i in d.overrides.indices where d.overrides[i].key == key { d.overrides[i].active = false }
        try commit(d)
    }

    public func activeOverride(key: String) -> OverrideRecord? {
        data.overrides.filter { $0.key == key && $0.active }.max { ($0.effectiveDate, $0.setAt) < ($1.effectiveDate, $1.setAt) }
    }

    private func coreOverrides(_ key: String, in d: AppData) -> [Override] {
        d.overrides.filter { $0.key == key }.compactMap { o in
            LocalDate(iso: o.effectiveDate).map {
                Override(value: o.value.value, effectiveDate: $0, setAt: ISO8601DateFormatter().string(from: o.setAt),
                         active: o.active)
            }
        }
    }

    // MARK: - 自動更新寫入（只寫快取，不碰手動值）

    /// 寫入自動報價；回傳實際更新的筆數。資料日較舊的不會覆蓋較新的快取。
    @discardableResult
    public func applyQuotes(_ quotes: [QuoteSnapshot], fetchedAt: Date? = nil) throws -> Int {
        var d = data
        var n = 0
        let t = fetchedAt ?? now()
        for q in quotes {
            guard let inst = d.instruments.first(where: { $0.market == q.market && $0.symbol == q.symbol }) else { continue }
            let key = inst.id.uuidString
            // 較舊的資料日不覆蓋目前快取，但仍記入歷史（月損益圖需要）
            let older = d.priceCache[key].flatMap { LocalDate(iso: $0.dataDate) }.map { $0 > q.dataDate } ?? false
            if !older {
                d.priceCache[key] = CacheEntry(value: Dec(q.close), dataDate: q.dataDate.iso, sourceId: q.sourceId,
                                               sourceURL: q.sourceURL, attribution: q.attribution, fetchedAt: t)
            }
            var hist = d.priceHistory[key] ?? []
            hist.removeAll { $0.date == q.dataDate.iso }
            hist.append(HistoryPoint(date: q.dataDate.iso, value: Dec(q.close)))
            hist.sort { $0.date < $1.date }
            d.priceHistory[key] = hist
            n += 1
        }
        try commit(d)
        return n
    }

    @discardableResult
    public func applyFx(currency: String, rate: Decimal, dataDate: LocalDate, sourceId: String, sourceURL: String,
                        attribution: String) throws -> Bool {
        var d = data
        if let old = d.fxCache[currency], let od = LocalDate(iso: old.dataDate), od > dataDate { return false }
        d.fxCache[currency] = CacheEntry(value: Dec(rate), dataDate: dataDate.iso, sourceId: sourceId,
                                         sourceURL: sourceURL, attribution: attribution, fetchedAt: now())
        var hist = d.fxHistory[currency] ?? []
        hist.removeAll { $0.date == dataDate.iso }
        hist.append(HistoryPoint(date: dataDate.iso, value: Dec(rate)))
        hist.sort { $0.date < $1.date }
        d.fxHistory[currency] = hist
        try commit(d)
        return true
    }

    public func markRefreshed(_ sourceKey: String, at date: Date? = nil) throws {
        var d = data
        d.lastRefresh[sourceKey] = date ?? now()
        try commit(d)
    }

    // MARK: - 估值（docs/02 §2）

    private func priceInput(_ inst: Instrument, in d: AppData) -> PriceInput {
        let c = d.priceCache[inst.id.uuidString]
        return PriceInput(overrides: coreOverrides(inst.id.uuidString, in: d), autoValue: c?.value.value,
                          autoDataDate: c.flatMap { LocalDate(iso: $0.dataDate) })
    }

    private func fxInput(_ ccy: String, in d: AppData) -> FxInput {
        let c = d.fxCache[ccy]
        return FxInput(overrides: coreOverrides(Self.fxKey(ccy), in: d), autoValue: c?.value.value,
                       autoDataDate: c.flatMap { LocalDate(iso: $0.dataDate) })
    }

    /// 目前價格與來源（手動 → 自動 → 無）；不含最後成交價。
    public func currentPrice(_ inst: Instrument) -> (Decimal?, PriceSource) {
        resolvePrice(priceInput(inst, in: data), asOf: today(market: inst.market), lastTradePrice: nil)
    }

    public func currentFx(_ ccy: String) -> (Decimal?, PriceSource) {
        resolveFx(currency: ccy, fxInput(ccy, in: data), asOf: today(market: Market.tw))
    }

    private func currentRates(_ d: AppData) -> [String: Decimal] {
        var r: [String: Decimal] = [:]
        let asOf = today(market: Market.tw)
        for ccy in Set(d.instruments.map(\.currency)).union(["USD", "JPY"]) {
            if let v = resolveFx(currency: ccy, fxInput(ccy, in: d), asOf: asOf).0 { r[ccy] = v }
        }
        return r
    }

    /// 費用幣別與標的不同且沒有交易日匯率時，以目前匯率換算。
    private func fxFallback(_ d: AppData) -> FxFallback {
        let rates = currentRates(d)
        return { from, to, _ in convert(1, from: from, to: to, rates: rates) ?? 0 }
    }

    public func overview(view: String) -> OverviewResult {
        let d = data
        let included = Set(d.portfolios.filter { $0.includeInOverview }.map(\.id))
        var holdings: [Holding] = []
        var broken: [String] = []
        let groups = Dictionary(grouping: d.transactions) { "\($0.portfolioId)|\($0.instrumentId)" }
        for (_, txs) in groups {
            guard let first = txs.first, let inst = d.instruments.first(where: { $0.id == first.instrumentId }) else { continue }
            do {
                let pos = try buildPosition(txs.map { try $0.coreTransaction() }, fxFallback: fxFallback(d))
                holdings.append(Holding(portfolioId: first.portfolioId.uuidString, instrumentId: inst.id.uuidString,
                                        currency: inst.currency, position: pos,
                                        includeInOverview: included.contains(first.portfolioId)))
            } catch {
                broken.append(inst.key)
            }
        }
        var prices: [String: PriceInput] = [:]
        for inst in d.instruments { prices[inst.id.uuidString] = priceInput(inst, in: d) }
        var fx: [String: FxInput] = [:]
        for ccy in ["USD", "JPY"] { fx[ccy] = fxInput(ccy, in: d) }
        let ov = DCACore.overview(holdings: holdings, prices: prices, fx: fx, view: view, asOf: today(market: Market.tw))

        let rates = currentRates(d)
        var total: Decimal = 0
        var unconvertible = 0
        let pend = pendingOccurrences
        for o in pend {
            guard let plan = d.plans.first(where: { $0.id == o.planId }), let amt = o.estAmount?.value else {
                unconvertible += 1
                continue
            }
            if let v = convert(amt, from: plan.currency, to: view, rates: rates) { total += v } else { unconvertible += 1 }
        }
        return OverviewResult(overview: ov,
                              pending: PendingSummary(count: pend.count, estimatedTotal: total, unconvertibleCount: unconvertible),
                              brokenHoldings: broken.sorted())
    }

    /// 全期間月損益（docs/05 §5）。歷史價格來自每次自動更新累積的收盤價，加上手動值與成交價。
    public func monthlyPoints(view: String, onlyCurrency: String? = nil) throws -> [MonthPoint] {
        let d = data
        let included = Set(d.portfolios.filter { $0.includeInOverview }.map(\.id))
        var hs: [SnapshotHolding] = []
        let groups = Dictionary(grouping: d.transactions.filter { included.contains($0.portfolioId) }) { $0.instrumentId }
        for (iid, txs) in groups {
            guard let inst = d.instruments.first(where: { $0.id == iid }) else { continue }
            hs.append(SnapshotHolding(instrumentId: iid.uuidString, currency: inst.currency,
                                      transactions: try txs.map { try $0.coreTransaction() }))
        }
        var ph: [String: Series] = [:]
        for inst in d.instruments {
            let key = inst.id.uuidString
            let pts = (d.priceHistory[key] ?? []).compactMap { p in LocalDate(iso: p.date).map { ($0, p.value.value) } }
            ph[key] = Series(points: pts, overrides: coreOverrides(key, in: d))
        }
        var fh: [String: Series] = [:]
        for ccy in ["USD", "JPY"] {
            let pts = (d.fxHistory[ccy] ?? []).compactMap { p in LocalDate(iso: p.date).map { ($0, p.value.value) } }
            fh[ccy] = Series(points: pts, overrides: coreOverrides(Self.fxKey(ccy), in: d))
        }
        return try monthlySnapshots(holdings: hs, priceHistory: ph, fxHistory: fh, view: view,
                                    asOf: today(market: Market.tw), onlyCurrency: onlyCurrency)
    }

    // MARK: - 清除

    /// 「清除所有資料並重新開始」：只能在確認文字正確時由 App 呼叫（docs/10 §6）。
    public func wipeAll() throws {
        try store.wipe()
        data = AppData()
    }
}
