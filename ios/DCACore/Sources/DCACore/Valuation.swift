import Foundation

/// 價格與匯率解析、幣別換算、合併總覽（docs/02 §2.2–2.4、docs/05 §3）。
/// 與 core/python/dca_core/valuation.py 一一對應。匯率為「1 單位幣別 = ? TWD」。
public enum PriceSource: String, Sendable {
    case manual = "MANUAL"
    case auto = "AUTO"
    case lastTrade = "LAST_TRADE"
    case cost = "COST"
    case none = "NONE"
}

public struct Override: Sendable {
    public var value: Decimal
    public var effectiveDate: LocalDate
    /// ISO 時間字串；同生效日時以較晚者為準
    public var setAt: String
    public var active: Bool

    public init(value: Decimal, effectiveDate: LocalDate, setAt: String, active: Bool = true) {
        self.value = value
        self.effectiveDate = effectiveDate
        self.setAt = setAt
        self.active = active
    }
}

public struct PriceInput: Sendable {
    public var overrides: [Override]
    public var autoValue: Decimal?
    public var autoDataDate: LocalDate?

    public init(overrides: [Override] = [], autoValue: Decimal? = nil, autoDataDate: LocalDate? = nil) {
        self.overrides = overrides
        self.autoValue = autoValue
        self.autoDataDate = autoDataDate
    }
}

public typealias FxInput = PriceInput

func activeOverride(_ overrides: [Override], asOf: LocalDate) -> Override? {
    overrides
        .filter { $0.active && $0.effectiveDate <= asOf }
        .max { ($0.effectiveDate, $0.setAt) < ($1.effectiveDate, $1.setAt) }
}

/// 優先序：使用者手動值 → 自動行情 → 最後成交價 → 無。
public func resolvePrice(_ input: PriceInput?, asOf: LocalDate, lastTradePrice: Decimal?) -> (Decimal?, PriceSource) {
    if let inp = input {
        if let o = activeOverride(inp.overrides, asOf: asOf) { return (Optional(o.value), .manual) }
        if let v = inp.autoValue { return (Optional(v), .auto) }
    }
    if let p = lastTradePrice { return (Optional(p), .lastTrade) }
    return (nil, .none)
}

public func resolveFx(currency: String, _ input: FxInput?, asOf: LocalDate) -> (Decimal?, PriceSource) {
    if currency == "TWD" { return (Optional(Decimal(1)), .auto) }
    if let inp = input {
        if let o = activeOverride(inp.overrides, asOf: asOf) { return (Optional(o.value), .manual) }
        if let v = inp.autoValue { return (Optional(v), .auto) }
    }
    return (nil, .none)
}

public func convert(_ amount: Decimal, from ccy: String, to view: String, rates: [String: Decimal]) -> Decimal? {
    if ccy == view { return amount }
    let rFrom: Decimal? = ccy == "TWD" ? Decimal(1) : rates[ccy]
    let rTo: Decimal? = view == "TWD" ? Decimal(1) : rates[view]
    guard let f = rFrom, let t = rTo else { return nil }
    return amount * f / t
}

public struct Holding: Sendable {
    public var portfolioId: String
    public var instrumentId: String
    public var currency: String
    public var position: Position
    public var includeInOverview: Bool

    public init(portfolioId: String, instrumentId: String, currency: String, position: Position, includeInOverview: Bool = true) {
        self.portfolioId = portfolioId
        self.instrumentId = instrumentId
        self.currency = currency
        self.position = position
        self.includeInOverview = includeInOverview
    }
}

public struct HoldingRow: Sendable {
    public var instrumentId: String
    public var currency: String
    public var quantity: Decimal
    public var avgCost: Decimal?
    public var price: Decimal?
    public var priceSource: PriceSource
    /// 原幣
    public var marketValue: Decimal
    public var marketValueView: Decimal?
}

public struct Overview: Sendable {
    public var view: String
    public var totalAssets: Decimal
    public var investedCurrent: Decimal
    public var historicalInvested: Decimal
    public var pnlExDiv: Decimal
    public var pnlIncDiv: Decimal
    public var returnExDiv: Decimal?
    public var returnIncDiv: Decimal?
    public var rows: [HoldingRow]
    public var missingFx: [String]
    public var estimatedInstruments: [String]
}

private struct Merged {
    var currency: String
    var qty: Decimal = 0
    var cost: Decimal = 0
    var reinv: Decimal = 0
    var hist: Decimal = 0
    var realized: Decimal = 0
    var divs: Decimal = 0
    var fees: Decimal = 0
    var last: Decimal?
}

public func overview(holdings: [Holding], prices: [String: PriceInput], fx: [String: FxInput], view: String, asOf: LocalDate) -> Overview {
    var rates: [String: Decimal] = [:]
    var missing = Set<String>()
    for c in Set(holdings.map(\.currency)).union([view]) {
        let (r, _) = resolveFx(currency: c, fx[c], asOf: asOf)
        if let r { rates[c] = r } else { missing.insert(c) }
    }

    var merged: [String: Merged] = [:]
    for h in holdings where h.includeInOverview {
        var m = merged[h.instrumentId] ?? Merged(currency: h.currency)
        let p = h.position
        m.qty += p.quantity
        m.cost += p.costBasis
        m.reinv += p.reinvestedCost
        m.hist += p.historicalInvested
        m.realized += p.realizedPnl
        m.divs += p.dividendsNet
        m.fees += p.standaloneFees
        if let l = p.lastTradePrice { m.last = l }
        merged[h.instrumentId] = m
    }

    var total: Decimal = 0, inv: Decimal = 0, hist: Decimal = 0, ex: Decimal = 0, divs: Decimal = 0
    var rows: [HoldingRow] = []
    var estimated: [String] = []
    for iid in merged.keys.sorted() {
        let m = merged[iid]!
        let ccy = m.currency
        var (price, src) = resolvePrice(prices[iid], asOf: asOf, lastTradePrice: m.last)
        let mv: Decimal
        if let p = price {
            mv = m.qty * p
        } else {
            mv = m.cost
            src = .cost
            price = nil
        }
        if (src == .lastTrade || src == .cost) && m.qty != 0 { estimated.append(iid) }
        let mvView: Decimal? = missing.contains(view) ? nil : convert(mv, from: ccy, to: view, rates: rates)
        rows.append(HoldingRow(instrumentId: iid, currency: ccy, quantity: m.qty,
                               avgCost: m.qty != 0 ? m.cost / m.qty : nil,
                               price: price, priceSource: src, marketValue: mv, marketValueView: mvView))
        guard let mvV = mvView else { continue }
        func cv(_ x: Decimal) -> Decimal { convert(x, from: ccy, to: view, rates: rates)! }
        total += mvV
        inv += cv(m.cost - m.reinv)
        hist += cv(m.hist)
        ex += cv(mv - m.cost + m.realized - m.fees)
        divs += cv(m.divs)
    }
    let inc = ex + divs
    return Overview(view: view, totalAssets: total, investedCurrent: inv, historicalInvested: hist,
                    pnlExDiv: ex, pnlIncDiv: inc,
                    returnExDiv: hist != 0 ? ex / hist : nil,
                    returnIncDiv: hist != 0 ? inc / hist : nil,
                    rows: rows, missingFx: missing.sorted(), estimatedInstruments: estimated)
}
