import DCACore
import Foundation

/// 以字串保存的十進位數。JSONDecoder 會把 JSON 數字經過 Double 轉換而失去精度，所以一律存字串。
public struct Dec: Codable, Hashable, Sendable, CustomStringConvertible {
    public var value: Decimal

    public init(_ value: Decimal) { self.value = value }

    public init?(string: String) {
        let s = string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard !s.isEmpty, let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        value = d
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let d = Dec(string: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid decimal \(s)")
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    public var description: String { "\(value)" }
}

public enum Market {
    public static let tw = "TW"
    public static let us = "US"
    public static let jp = "JP"
    public static let fundTW = "FUND_TW"

    public static func currency(_ market: String) -> String {
        switch market {
        case us: return "USD"
        case jp: return "JPY"
        default: return "TWD"
        }
    }

    /// 交易日曆與時區用的市場代碼（台灣基金依台灣營業日）
    public static func calendarKey(_ market: String) -> String {
        market == fundTW ? tw : market
    }
}

public struct Portfolio: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var note: String?
    public var colorHex: String
    public var defaultCurrency: String
    public var includeInOverview: Bool
    public var sortOrder: Int
    public var archivedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct Instrument: Codable, Identifiable, Hashable {
    public var id: UUID
    public var market: String
    public var board: String?
    public var symbol: String
    public var name: String
    public var assetType: String  // STOCK / ETF / FUND
    public var currency: String
    public var isUserDefined: Bool

    /// 例如 TW:2330、US:AAPL
    public var key: String { "\(market):\(symbol)" }
}

public enum AmountMode: String, Codable { case amount = "AMOUNT", quantity = "QUANTITY" }
public enum FeeMode: String, Codable { case fixed = "FIXED", rate = "RATE" }

public struct PlanRecord: Codable, Identifiable, Hashable {
    public var id: UUID
    public var portfolioId: UUID
    public var instrumentId: UUID
    public var amountMode: AmountMode
    public var amount: Dec
    public var currency: String
    public var frequency: String  // WEEKLY / MONTHLY / DATES
    public var weekdays: [Int]
    public var monthDays: [Int]
    public var specificDates: [String]
    public var holidayRule: String
    public var startDate: String
    public var endDate: String?
    /// 從這天（名義日）開始產生待確認；新增舊計畫時由使用者決定是否補產生（docs/02 §3.3）
    public var generateFrom: String
    public var feeMode: FeeMode
    public var feeValue: Dec
    public var feeMin: Dec
    public var feeCurrency: String
    public var paused: Bool
    public var note: String?

    public init(id: UUID = UUID(), portfolioId: UUID, instrumentId: UUID, amountMode: AmountMode = .amount,
                amount: Dec, currency: String, frequency: String, weekdays: [Int] = [], monthDays: [Int] = [],
                specificDates: [String] = [], holidayRule: String = HolidayRule.nextTradingDay.rawValue,
                startDate: String, endDate: String? = nil, generateFrom: String? = nil,
                feeMode: FeeMode = .fixed, feeValue: Dec = Dec(0), feeMin: Dec = Dec(0), feeCurrency: String? = nil,
                paused: Bool = false, note: String? = nil) {
        self.id = id
        self.portfolioId = portfolioId
        self.instrumentId = instrumentId
        self.amountMode = amountMode
        self.amount = amount
        self.currency = currency
        self.frequency = frequency
        self.weekdays = weekdays
        self.monthDays = monthDays
        self.specificDates = specificDates
        self.holidayRule = holidayRule
        self.startDate = startDate
        self.endDate = endDate
        self.generateFrom = generateFrom ?? startDate
        self.feeMode = feeMode
        self.feeValue = feeValue
        self.feeMin = feeMin
        self.feeCurrency = feeCurrency ?? currency
        self.paused = paused
        self.note = note
    }

    public func corePlan() throws -> Plan {
        guard let start = LocalDate(iso: startDate),
              let freq = Frequency(rawValue: frequency),
              let rule = HolidayRule(rawValue: holidayRule) else { throw BookError.invalidPlan("日期或頻率格式錯誤") }
        let end = try endDate.map { s -> LocalDate in
            guard let d = LocalDate(iso: s) else { throw BookError.invalidPlan("結束日格式錯誤") }
            return d
        }
        if let e = end, e < start { throw BookError.invalidPlan("結束日早於開始日") }
        let dates = try specificDates.map { s -> LocalDate in
            guard let d = LocalDate(iso: s) else { throw BookError.invalidPlan("指定日期格式錯誤") }
            return d
        }
        do {
            return try Plan(frequency: freq, startDate: start, endDate: end, weekdays: weekdays, monthDays: monthDays,
                            specificDates: dates, holidayRule: rule, paused: paused)
        } catch {
            throw BookError.invalidPlan("\(error)")
        }
    }

    /// 依計畫的手續費設定估算手續費（固定金額，或費率並套用最低收費）。
    public func estimatedFee(for gross: Decimal) -> Decimal {
        switch feeMode {
        case .fixed: return feeValue.value
        case .rate: return max(gross * feeValue.value, feeMin.value)
        }
    }
}

public enum OccurrenceStatus: String, Codable { case pending = "PENDING", confirmed = "CONFIRMED", skipped = "SKIPPED" }

public struct OccurrenceRecord: Codable, Identifiable, Hashable {
    public var id: UUID
    public var planId: UUID
    public var periodKey: String
    public var nominalDate: String
    public var scheduledDate: String
    public var adjustReasons: [String]
    public var mergedKeys: [String]
    public var calendarUnknown: Bool
    public var status: OccurrenceStatus
    public var estPrice: Dec?
    public var estQuantity: Dec?
    public var estAmount: Dec?
    public var transactionId: UUID?
}

public struct TransactionRecord: Codable, Identifiable, Hashable {
    public var id: UUID
    public var portfolioId: UUID
    public var instrumentId: UUID
    public var type: String  // DCACore.TxType rawValue
    public var tradeDate: String
    public var price: Dec?
    public var quantity: Dec?
    public var grossAmount: Dec
    public var fee: Dec
    public var tax: Dec
    public var otherCost: Dec
    public var costCurrency: String?
    public var currency: String
    public var fxRateAtTrade: Dec?
    public var occurrenceId: UUID?
    public var note: String?
    public var seq: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), portfolioId: UUID, instrumentId: UUID, type: TxType, tradeDate: String,
                price: Dec? = nil, quantity: Dec? = nil, grossAmount: Dec = Dec(0), fee: Dec = Dec(0),
                tax: Dec = Dec(0), otherCost: Dec = Dec(0), costCurrency: String? = nil, currency: String,
                fxRateAtTrade: Dec? = nil, occurrenceId: UUID? = nil, note: String? = nil, seq: Int = 0,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.portfolioId = portfolioId
        self.instrumentId = instrumentId
        self.type = type.rawValue
        self.tradeDate = tradeDate
        self.price = price
        self.quantity = quantity
        self.grossAmount = grossAmount
        self.fee = fee
        self.tax = tax
        self.otherCost = otherCost
        self.costCurrency = costCurrency
        self.currency = currency
        self.fxRateAtTrade = fxRateAtTrade
        self.occurrenceId = occurrenceId
        self.note = note
        self.seq = seq
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func coreTransaction() throws -> Transaction {
        guard let t = TxType(rawValue: type) else { throw BookError.ledger("UNKNOWN_TYPE") }
        guard let d = LocalDate(iso: tradeDate) else { throw BookError.invalidDate(tradeDate) }
        return Transaction(type: t, tradeDate: d, currency: currency, grossAmount: grossAmount.value,
                           price: price?.value, quantity: quantity?.value, fee: fee.value, tax: tax.value,
                           otherCost: otherCost.value, costCurrency: costCurrency,
                           fxRateAtTrade: fxRateAtTrade?.value, seq: seq)
    }
}

/// 手動價格或匯率。key：價格為 instrumentId 的字串；匯率為 "FX:USD" 等。
public struct OverrideRecord: Codable, Identifiable, Hashable {
    public var id: UUID
    public var key: String
    public var value: Dec
    public var effectiveDate: String
    public var setAt: Date
    public var active: Bool
    public var note: String?
}

/// 自動取得的值（可重建）。
public struct CacheEntry: Codable, Hashable {
    public var value: Dec
    public var dataDate: String
    public var sourceId: String
    public var sourceURL: String
    public var attribution: String
    public var fetchedAt: Date
}

public struct HistoryPoint: Codable, Hashable {
    public var date: String
    public var value: Dec
}

public struct AppData: Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = AppData.currentSchemaVersion
    public var portfolios: [Portfolio] = []
    public var instruments: [Instrument] = []
    public var plans: [PlanRecord] = []
    public var occurrences: [OccurrenceRecord] = []
    public var transactions: [TransactionRecord] = []
    public var overrides: [OverrideRecord] = []
    /// key：instrumentId 字串
    public var priceCache: [String: CacheEntry] = [:]
    public var priceHistory: [String: [HistoryPoint]] = [:]
    /// key："USD"、"JPY"（1 單位 = ? TWD）
    public var fxCache: [String: CacheEntry] = [:]
    public var fxHistory: [String: [HistoryPoint]] = [:]
    /// 休市日（使用者或日後的官方來源匯入）；沒有資料時只排除週末並標示「日曆未更新」
    public var holidays: [String: [String]] = [:]
    public var holidaysKnownThrough: [String: String] = [:]
    /// 各資料來源最後一次成功更新的時間
    public var lastRefresh: [String: Date] = [:]
    public var nextSeq = 1

    public init() {}
}
