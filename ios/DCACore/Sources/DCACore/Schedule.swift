import Foundation

/// 定期定額期別產生（docs/02 §3）。與 core/python/dca_core/schedule.py 一一對應。
public enum Frequency: String, Sendable {
    case weekly = "WEEKLY"
    case monthly = "MONTHLY"
    case dates = "DATES"
}

public enum HolidayRule: String, Sendable {
    case nextTradingDay = "NEXT_TRADING_DAY"
    case prevTradingDay = "PREV_TRADING_DAY"
}

/// PREV 規則可能讓下個月初的名義日提前到今天以前，所以往後多看一段。
public let scheduleLookaheadDays = 31

public struct Plan: Sendable {
    public var frequency: Frequency
    public var startDate: LocalDate
    public var endDate: LocalDate?
    public var weekdays: [Int]
    public var monthDays: [Int]
    public var specificDates: [LocalDate]
    public var holidayRule: HolidayRule
    public var paused: Bool

    public init(
        frequency: Frequency,
        startDate: LocalDate,
        endDate: LocalDate? = nil,
        weekdays: [Int] = [],
        monthDays: [Int] = [],
        specificDates: [LocalDate] = [],
        holidayRule: HolidayRule = .nextTradingDay,
        paused: Bool = false
    ) throws {
        if frequency == .weekly && weekdays.isEmpty { throw CoreError.invalidPlan("weekly plan needs weekdays") }
        if frequency == .monthly && monthDays.isEmpty { throw CoreError.invalidPlan("monthly plan needs month_days") }
        if frequency == .dates && specificDates.isEmpty { throw CoreError.invalidPlan("dates plan needs specific_dates") }
        if weekdays.contains(where: { !(1...7).contains($0) }) { throw CoreError.invalidPlan("weekday must be 1..7") }
        if monthDays.contains(where: { !(1...31).contains($0) }) { throw CoreError.invalidPlan("month day must be 1..31") }
        self.frequency = frequency
        self.startDate = startDate
        self.endDate = endDate
        self.weekdays = weekdays
        self.monthDays = monthDays
        self.specificDates = specificDates
        self.holidayRule = holidayRule
        self.paused = paused
    }
}

public struct Occurrence: Equatable, Sendable {
    public var periodKey: String
    public var nominalDate: LocalDate
    public var scheduledDate: LocalDate
    public var adjustReasons: [String]
    public var mergedKeys: [String]
    public var calendarUnknown: Bool
}

private func iterMonths(_ lo: LocalDate, _ hi: LocalDate) -> [(Int, Int)] {
    var out: [(Int, Int)] = []
    var y = lo.year, m = lo.month
    while (y, m) <= (hi.year, hi.month) {
        out.append((y, m))
        m += 1
        if m == 13 { y += 1; m = 1 }
    }
    return out
}

private func nominalDates(_ plan: Plan, _ lo: LocalDate, _ hi: LocalDate) -> [(String, LocalDate, [String])] {
    var out: [(String, LocalDate, [String])] = []
    if lo > hi { return out }
    switch plan.frequency {
    case .weekly:
        let wanted = Set(plan.weekdays)
        var d = lo
        while d <= hi {
            let wd = d.isoWeekday
            if wanted.contains(wd) {
                let (iy, iw) = d.isoYearWeek
                out.append((String(format: "%d-W%02d#%d", iy, iw, wd), d, []))
            }
            d = d.adding(days: 1)
        }
    case .monthly:
        let days = Array(Set(plan.monthDays)).sorted()
        for (y, m) in iterMonths(lo, hi) {
            let dim = LocalDate.daysInMonth(year: y, month: m)
            for md in days {
                let nd = LocalDate(y, m, min(md, dim))
                if lo <= nd && nd <= hi {
                    out.append((String(format: "%d-%02d#%d", y, m, md), nd, md > dim ? ["MONTH_END"] : []))
                }
            }
        }
    case .dates:
        for sd in Array(Set(plan.specificDates)).sorted() where lo <= sd && sd <= hi {
            out.append(("D" + sd.iso, sd, []))
        }
    }
    return out
}

private func schedule(_ plan: Plan, _ cal: TradingCalendar, _ lo: LocalDate, _ hi: LocalDate) throws -> [Occurrence] {
    var occs: [Occurrence] = []
    for (key, nd, baseReasons) in nominalDates(plan, lo, hi) {
        var reasons = baseReasons
        let sd: LocalDate
        if cal.isOpen(nd) {
            sd = nd
        } else if plan.holidayRule == .nextTradingDay {
            sd = try cal.nextOpen(nd)
            reasons.append("HOLIDAY_FORWARD")
        } else {
            sd = try cal.prevOpen(nd)
            reasons.append("HOLIDAY_BACKWARD")
        }
        occs.append(Occurrence(periodKey: key, nominalDate: nd, scheduledDate: sd,
                               adjustReasons: reasons, mergedKeys: [],
                               calendarUnknown: !cal.isKnown(sd)))
    }
    // 標示同一天的合併期別（保留產生順序）
    var byDay: [LocalDate: [String]] = [:]
    for o in occs { byDay[o.scheduledDate, default: []].append(o.periodKey) }
    var result: [Occurrence] = []
    for var o in occs {
        let keys = byDay[o.scheduledDate] ?? []
        if keys.count > 1 {
            o.adjustReasons.append("MERGED")
            o.mergedKeys = keys.filter { $0 != o.periodKey }
        }
        result.append(o)
    }
    result.sort { ($0.scheduledDate, $0.nominalDate, $0.periodKey) < ($1.scheduledDate, $1.nominalDate, $1.periodKey) }
    return result
}

/// 應產生為「待確認」的期別：scheduledDate <= today，且 periodKey 尚未存在。
public func dueOccurrences(
    plan: Plan,
    calendar: TradingCalendar,
    today: LocalDate,
    existingKeys: Set<String> = [],
    since: LocalDate? = nil
) throws -> [Occurrence] {
    if plan.paused { return [] }
    let lo = since.map { max(plan.startDate, $0) } ?? plan.startDate
    var hi = today.adding(days: scheduleLookaheadDays)
    if let end = plan.endDate { hi = min(hi, end) }
    return try schedule(plan, calendar, lo, hi).filter {
        $0.scheduledDate <= today && !existingKeys.contains($0.periodKey)
    }
}

/// 編輯畫面的「接下來 n 期」預覽：scheduledDate > today。
public func upcomingOccurrences(plan: Plan, calendar: TradingCalendar, today: LocalDate, count: Int) throws -> [Occurrence] {
    if plan.paused || count <= 0 { return [] }
    let lo = max(plan.startDate, today.adding(days: -scheduleLookaheadDays))
    var span = 400
    while true {
        var hi = today.adding(days: span)
        if let end = plan.endDate { hi = min(hi, end) }
        let out = try schedule(plan, calendar, lo, hi).filter { $0.scheduledDate > today }
        let reachedEnd = plan.endDate.map { hi >= $0 } ?? false
        if out.count >= count || reachedEnd || span > 3700 {
            return Array(out.prefix(count))
        }
        span *= 2
    }
}
