import Foundation

/// 不含時區的日曆日期（等同 Python `datetime.date`）。
/// 以 1970-01-01 起算的天數做加減，避免 Foundation.Calendar 的時區問題。
public struct LocalDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(_ year: Int, _ month: Int, _ day: Int) {
        precondition((1...12).contains(month), "month out of range")
        precondition(day >= 1 && day <= LocalDate.daysInMonth(year: year, month: month), "day out of range")
        self.year = year
        self.month = month
        self.day = day
    }

    /// 解析 "YYYY-MM-DD"。
    public init?(iso: String) {
        let parts = iso.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= LocalDate.daysInMonth(year: y, month: m)
        else { return nil }
        self.init(y, m, d)
    }

    public init(daysSinceEpoch z0: Int) {
        // Howard Hinnant, civil_from_days
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(m <= 2 ? y + 1 : y, m, d)
    }

    public var daysSinceEpoch: Int {
        // Howard Hinnant, days_from_civil
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public var iso: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { iso }

    public func adding(days: Int) -> LocalDate {
        LocalDate(daysSinceEpoch: daysSinceEpoch + days)
    }

    /// ISO 星期：週一 = 1 … 週日 = 7。1970-01-01 是週四。
    public var isoWeekday: Int {
        (((daysSinceEpoch + 3) % 7) + 7) % 7 + 1
    }

    /// ISO 週年與週次（例如 2027-01-01 → (2026, 53)）。
    public var isoYearWeek: (year: Int, week: Int) {
        let thursday = daysSinceEpoch - (isoWeekday - 4)
        let y = LocalDate(daysSinceEpoch: thursday).year
        let jan1 = LocalDate(y, 1, 1).daysSinceEpoch
        return (y, (thursday - jan1) / 7 + 1)
    }

    public var firstOfMonth: LocalDate { LocalDate(year, month, 1) }

    public var endOfMonth: LocalDate { LocalDate(year, month, LocalDate.daysInMonth(year: year, month: month)) }

    public static func isLeap(_ y: Int) -> Bool {
        (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    public static func < (a: LocalDate, b: LocalDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}
