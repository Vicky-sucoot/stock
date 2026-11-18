import Foundation

/// 單一持有部位的交易回放：移動平均成本法（docs/02 §2.1）。
/// 與 core/python/dca_core/ledger.py 一一對應；口徑說明見該檔案的 docstring。
public enum TxType: String, Sendable {
    case buy = "BUY"
    case sell = "SELL"
    case dividendCash = "DIVIDEND_CASH"
    case dividendStock = "DIVIDEND_STOCK"
    case dividendReinvest = "DIVIDEND_REINVEST"
    case fee = "FEE"
    case splitAdjust = "SPLIT_ADJUST"
}

/// code：OVERSELL / FX_REQUIRED / INVALID_QUANTITY / INVALID_SPLIT / UNKNOWN_TYPE
public struct LedgerError: Error, Equatable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String = "") {
        self.code = code
        self.message = message
    }
}

public struct Transaction: Sendable {
    public var type: TxType
    public var tradeDate: LocalDate
    public var currency: String
    public var grossAmount: Decimal
    public var price: Decimal?
    public var quantity: Decimal?
    public var fee: Decimal
    public var tax: Decimal
    public var otherCost: Decimal
    public var costCurrency: String?
    /// 1 單位 currency = ? TWD
    public var fxRateAtTrade: Decimal?
    /// 同日排序
    public var seq: Int

    public init(
        type: TxType, tradeDate: LocalDate, currency: String,
        grossAmount: Decimal = 0, price: Decimal? = nil, quantity: Decimal? = nil,
        fee: Decimal = 0, tax: Decimal = 0, otherCost: Decimal = 0,
        costCurrency: String? = nil, fxRateAtTrade: Decimal? = nil, seq: Int = 0
    ) {
        self.type = type
        self.tradeDate = tradeDate
        self.currency = currency
        self.grossAmount = grossAmount
        self.price = price
        self.quantity = quantity
        self.fee = fee
        self.tax = tax
        self.otherCost = otherCost
        self.costCurrency = costCurrency
        self.fxRateAtTrade = fxRateAtTrade
        self.seq = seq
    }
}

public struct Position: Equatable, Sendable {
    public var quantity: Decimal
    public var costBasis: Decimal
    public var reinvestedCost: Decimal
    public var historicalInvested: Decimal
    public var realizedPnl: Decimal
    public var dividendsNet: Decimal
    public var standaloneFees: Decimal
    public var lastTradePrice: Decimal?

    public var investedCurrent: Decimal { costBasis - reinvestedCost }

    public var avgCost: Decimal? { quantity == 0 ? nil : costBasis / quantity }
}

public typealias FxFallback = (_ from: String, _ to: String, _ date: LocalDate) -> Decimal

private func costsInCurrency(_ t: Transaction, _ fxFallback: FxFallback?) throws -> Decimal {
    let total = t.fee + t.tax + t.otherCost
    let cc = t.costCurrency ?? t.currency
    if cc == t.currency || total == 0 { return total }
    if cc == "TWD", let r = t.fxRateAtTrade, r != 0 { return total / r }
    if t.currency == "TWD", let r = t.fxRateAtTrade, r != 0 { return total * r }
    guard let fb = fxFallback else {
        throw LedgerError("FX_REQUIRED", "\(cc)->\(t.currency) on \(t.tradeDate)")
    }
    return total * fb(cc, t.currency, t.tradeDate)
}

private func requireQuantity(_ t: Transaction) throws -> Decimal {
    guard let q = t.quantity, q > 0 else {
        throw LedgerError("INVALID_QUANTITY", "\(t.type.rawValue) on \(t.tradeDate)")
    }
    return q
}

public func buildPosition(_ transactions: [Transaction], asOf: LocalDate? = nil, fxFallback: FxFallback? = nil) throws -> Position {
    var qty: Decimal = 0
    var cost: Decimal = 0
    var reinv: Decimal = 0
    var hist: Decimal = 0
    var realized: Decimal = 0
    var divs: Decimal = 0
    var fees: Decimal = 0
    var lastPrice: Decimal?

    let ordered = transactions.enumerated().sorted {
        ($0.element.tradeDate, $0.element.seq, $0.offset) < ($1.element.tradeDate, $1.element.seq, $1.offset)
    }
    for (_, t) in ordered {
        if let a = asOf, t.tradeDate > a { continue }
        let extra = try costsInCurrency(t, fxFallback)
        switch t.type {
        case .buy:
            let q = try requireQuantity(t)
            let total = t.grossAmount + extra
            qty += q
            cost += total
            hist += total
            if let p = t.price { lastPrice = p }
        case .sell:
            let q = try requireQuantity(t)
            if q > qty { throw LedgerError("OVERSELL", "sell \(q) > holding \(qty) on \(t.tradeDate)") }
            let removed = cost * q / qty
            let removedReinv = reinv * q / qty
            let proceeds = t.grossAmount - extra
            realized += proceeds - removed
            qty -= q
            if qty == 0 {
                cost = 0
                reinv = 0
            } else {
                cost -= removed
                reinv -= removedReinv
            }
            if let p = t.price { lastPrice = p }
        case .dividendCash:
            divs += t.grossAmount - extra
        case .dividendReinvest:
            let q = try requireQuantity(t)
            let net = t.grossAmount - extra
            divs += net
            qty += q
            cost += net
            reinv += net
            if let p = t.price { lastPrice = p }
        case .dividendStock:
            qty += try requireQuantity(t)
        case .splitAdjust:
            let ratio = try requireQuantity(t)
            qty *= ratio
        case .fee:
            fees += t.grossAmount + extra
        }
    }
    return Position(quantity: qty, costBasis: cost, reinvestedCost: reinv, historicalInvested: hist,
                    realizedPnl: realized, dividendsNet: divs, standaloneFees: fees, lastTradePrice: lastPrice)
}
