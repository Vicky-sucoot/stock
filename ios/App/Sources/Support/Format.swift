import DCACore
import DCAKit
import Foundation

enum Fmt {
    private static func formatter(_ digits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.numberStyle = .decimal
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        f.roundingMode = .halfEven
        return f
    }

    static func digits(for currency: String) -> Int { currency == "USD" ? 2 : 0 }

    static func symbol(_ currency: String) -> String {
        switch currency {
        case "USD": return "US$"
        case "JPY": return "¥"
        default: return "NT$"
        }
    }

    static func money(_ v: Decimal?, _ currency: String) -> String {
        guard let v else { return "—" }
        let s = formatter(digits(for: currency)).string(from: v as NSDecimalNumber) ?? "\(v)"
        return symbol(currency) + s
    }

    static func signedMoney(_ v: Decimal?, _ currency: String) -> String {
        guard let v else { return "—" }
        return (v > 0 ? "+" : "") + money(v, currency)
    }

    static func number(_ v: Decimal?, digits: Int = 2) -> String {
        guard let v else { return "—" }
        return formatter(digits).string(from: v as NSDecimalNumber) ?? "\(v)"
    }

    /// 股數或單位數：最多 6 位小數，去除多餘的 0
    static func quantity(_ v: Decimal?) -> String {
        guard let v else { return "—" }
        let f = formatter(0)
        f.maximumFractionDigits = 6
        return f.string(from: v as NSDecimalNumber) ?? "\(v)"
    }

    static func percent(_ v: Decimal?) -> String {
        guard let v else { return "—" }
        let p = v * 100
        return (p > 0 ? "+" : "") + (formatter(2).string(from: p as NSDecimalNumber) ?? "\(p)") + "%"
    }

    static func dateTime(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "M/d HH:mm"
        return f.string(from: d)
    }

    static func shortDate(_ iso: String) -> String {
        guard let d = LocalDate(iso: iso) else { return iso }
        return "\(d.year)/\(d.month)/\(d.day)"
    }

    static func decimal(_ text: String) -> Decimal? { Dec(string: text)?.value }

    static func reason(_ r: String) -> String {
        switch r {
        case "MONTH_END": return "當月無此日，改為月底"
        case "HOLIDAY_FORWARD": return "遇休市順延"
        case "HOLIDAY_BACKWARD": return "遇休市提前"
        case "MERGED": return "與其他期別同一天"
        default: return r
        }
    }
}

extension LocalDate {
    /// DatePicker 用：以手機目前的曆法與時區轉換
    var date: Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    init(date: Date) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        self.init(c.year!, c.month!, c.day!)
    }
}
