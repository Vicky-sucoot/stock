import Foundation

/// 全期間月資料點（docs/05 §5）。與 core/python/dca_core/snapshots.py 一一對應。
public struct Series: Sendable {
    /// 依日期排序
    public var points: [(LocalDate, Decimal)]
    public var overrides: [Override]

    public init(points: [(LocalDate, Decimal)] = [], overrides: [Override] = []) {
        self.points = points.sorted { $0.0 < $1.0 }
        self.overrides = overrides
    }

    /// (value, valueDate, isManual)：手動值優先，否則取 d 當天或之前最近一筆。
    public func at(_ d: LocalDate) -> (Decimal?, LocalDate?, Bool) {
        if let o = activeOverride(overrides, asOf: d) { return (Optional(o.value), Optional(d), true) }
        guard let last = points.last(where: { $0.0 <= d }) else { return (nil, nil, false) }
        return (Optional(last.1), Optional(last.0), false)
    }
}

public struct SnapshotHolding: Sendable {
    public var instrumentId: String
    public var currency: String
    public var transactions: [Transaction]
    public var includeInOverview: Bool

    public init(instrumentId: String, currency: String, transactions: [Transaction], includeInOverview: Bool = true) {
        self.instrumentId = instrumentId
        self.currency = currency
        self.transactions = transactions
        self.includeInOverview = includeInOverview
    }
}

public struct MonthPoint: Sendable {
    public var month: String
    public var date: LocalDate
    public var marketValue: Decimal
    public var investedCurrent: Decimal
    public var historicalInvested: Decimal
    public var pnlExDiv: Decimal
    public var pnlIncDiv: Decimal
    public var estimated: Bool
    public var estimatedItems: [String]
    public var missingFx: [String]
}

private func monthEnds(first: LocalDate, asOf: LocalDate) -> [(String, LocalDate)] {
    var out: [(String, LocalDate)] = []
    var y = first.year, m = first.month
    while (y, m) <= (asOf.year, asOf.month) {
        let label = String(format: "%d-%02d", y, m)
        if (y, m) == (asOf.year, asOf.month) {
            out.append((label, asOf))
        } else {
            out.append((label, LocalDate(y, m, LocalDate.daysInMonth(year: y, month: m))))
        }
        m += 1
        if m == 13 { y += 1; m = 1 }
    }
    return out
}

/// `onlyCurrency`：例如 "USD" 時只計該幣別資產且不換算（USD 檢視的「原幣」模式）。
public func monthlySnapshots(
    holdings: [SnapshotHolding],
    priceHistory: [String: Series],
    fxHistory: [String: Series],
    view viewIn: String,
    asOf: LocalDate,
    onlyCurrency: String? = nil
) throws -> [MonthPoint] {
    var hs = holdings.filter(\.includeInOverview)
    var view = viewIn
    if let oc = onlyCurrency {
        hs = hs.filter { $0.currency == oc }
        view = oc
    }
    let allDates = hs.flatMap { $0.transactions.map(\.tradeDate) }
    guard let first = allDates.min() else { return [] }

    var out: [MonthPoint] = []
    for (month, d) in monthEnds(first: first, asOf: asOf) {
        let monthStart = d.firstOfMonth
        var rates: [String: Decimal] = [:]
        var estItems: [String] = []
        var missing = Set<String>()
        // 原幣模式下所有資產幣別都等於檢視幣別，不需要匯率
        let needed: Set<String> = onlyCurrency != nil ? [] : Set(hs.map(\.currency)).union([view])
        for c in needed where c != "TWD" {
            let (v, vd, manual) = (fxHistory[c] ?? Series()).at(d)
            guard let v else { missing.insert(c); continue }
            rates[c] = v
            if !manual, let vd, vd < monthStart { estItems.append("FX:\(c)") }
        }
        var mvT: Decimal = 0, invT: Decimal = 0, histT: Decimal = 0, exT: Decimal = 0, divT: Decimal = 0
        for h in hs {
            let pos = try buildPosition(h.transactions, asOf: d)
            if pos.quantity == 0 && pos.historicalInvested == 0 && pos.dividendsNet == 0 && pos.standaloneFees == 0 {
                continue
            }
            var (p, pd, manual) = (priceHistory[h.instrumentId] ?? Series()).at(d)
            var stale = p != nil && !manual && pd != nil && pd! < monthStart
            if p == nil, let ltp = pos.lastTradePrice {
                p = ltp
                stale = true
            }
            let mv: Decimal = p.map { pos.quantity * $0 } ?? pos.costBasis
            if (p == nil || stale) && pos.quantity != 0 {
                estItems.append("PRICE:\(h.instrumentId)")
            }
            if missing.contains(h.currency) || missing.contains(view) { continue }
            func cv(_ x: Decimal) -> Decimal { convert(x, from: h.currency, to: view, rates: rates)! }
            mvT += cv(mv)
            invT += cv(pos.investedCurrent)
            histT += cv(pos.historicalInvested)
            exT += cv(mv - pos.costBasis + pos.realizedPnl - pos.standaloneFees)
            divT += cv(pos.dividendsNet)
        }
        let items = Array(Set(estItems)).sorted()
        out.append(MonthPoint(month: month, date: d, marketValue: mvT, investedCurrent: invT,
                              historicalInvested: histT, pnlExDiv: exT, pnlIncDiv: exT + divT,
                              estimated: !items.isEmpty || !missing.isEmpty,
                              estimatedItems: items, missingFx: missing.sorted()))
    }
    return out
}
