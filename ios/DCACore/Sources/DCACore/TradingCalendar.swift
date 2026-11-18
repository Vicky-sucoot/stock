import Foundation

public enum CoreError: Error, Equatable {
    case noTradingDay(LocalDate)
    case invalidPlan(String)
    case unknownMarket(String)
}

/// 交易日曆：週末一律休市，`holidays` 為額外休市日。
/// `knownThrough` 之後的日期視為「日曆未更新」，只排除週末，並由呼叫端標示。
public struct TradingCalendar: Sendable {
    public static let maxAdjustDays = 30

    public var holidays: Set<LocalDate>
    public var knownThrough: LocalDate?

    public init(holidays: Set<LocalDate> = [], knownThrough: LocalDate? = nil) {
        self.holidays = holidays
        self.knownThrough = knownThrough
    }

    public func isOpen(_ d: LocalDate) -> Bool {
        if d.isoWeekday >= 6 { return false }
        return !holidays.contains(d)
    }

    public func isKnown(_ d: LocalDate) -> Bool {
        guard let k = knownThrough else { return true }
        return d <= k
    }

    public func nextOpen(_ d: LocalDate) throws -> LocalDate { try walk(d, step: 1) }

    public func prevOpen(_ d: LocalDate) throws -> LocalDate { try walk(d, step: -1) }

    private func walk(_ d: LocalDate, step: Int) throws -> LocalDate {
        var cur = d
        for _ in 0...TradingCalendar.maxAdjustDays {
            if isOpen(cur) { return cur }
            cur = cur.adding(days: step)
        }
        throw CoreError.noTradingDay(d)
    }
}

public let marketTimeZones: [String: String] = [
    "TW": "Asia/Taipei",
    "FUND_TW": "Asia/Taipei",
    "US": "America/New_York",
    "JP": "Asia/Tokyo",
]

/// 以市場時區判斷「今天」的日期（docs/02 §3.3）。
public func marketToday(market: String, now: Date) throws -> LocalDate {
    guard let id = marketTimeZones[market], let tz = TimeZone(identifier: id) else {
        throw CoreError.unknownMarket(market)
    }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    let c = cal.dateComponents([.year, .month, .day], from: now)
    return LocalDate(c.year!, c.month!, c.day!)
}
