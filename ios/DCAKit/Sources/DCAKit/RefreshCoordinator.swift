import Foundation

public struct RefreshReport: Equatable {
    public var updated = 0
    public var skippedSources: [String] = []
    public var errors: [String] = []
    public var finishedAt: Date?
}

/// 開啟 App 時更新行情（docs/05 §2）。只寫入自動快取，永遠不改手動值。
/// 失敗時保留上次資料並回報原因，不丟出例外。
public final class RefreshCoordinator {
    public static let twKey = "TW_QUOTES"
    public static let usKey = "US_QUOTES"

    private let book: PortfolioBook
    private let direct: DirectTaiwanOpenAPISource?
    private let backend: BackendQuoteSource?
    private let finnhub: FinnhubQuoteSource?
    private let now: () -> Date
    /// 直接呼叫官方 OpenAPI 時的最短間隔（清單較大、資料一天只更新一次）
    public var directMinInterval: TimeInterval = 6 * 3600
    /// 後端與美股的最短間隔
    public var minInterval: TimeInterval = 15 * 60

    public init(book: PortfolioBook, direct: DirectTaiwanOpenAPISource? = nil, backend: BackendQuoteSource? = nil,
                finnhub: FinnhubQuoteSource? = nil, now: @escaping () -> Date = Date.init) {
        self.book = book
        self.direct = direct
        self.backend = backend
        self.finnhub = finnhub
        self.now = now
    }

    private func due(_ key: String, interval: TimeInterval, force: Bool) -> Bool {
        guard !force, let last = book.data.lastRefresh[key] else { return true }
        return now().timeIntervalSince(last) >= interval
    }

    public func refresh(force: Bool = false) async -> RefreshReport {
        var report = RefreshReport()
        let tw = book.data.instruments.filter { $0.market == Market.tw }.map(\.symbol)
        let us = book.data.instruments.filter { $0.market == Market.us && !$0.isUserDefined }.map(\.symbol)

        if !tw.isEmpty {
            let interval = backend != nil ? minInterval : directMinInterval
            if due(Self.twKey, interval: interval, force: force) {
                do {
                    let quotes: [QuoteSnapshot]
                    if let b = backend {
                        quotes = try await b.fetch(twSymbols: tw)
                    } else if let d = direct {
                        let listing = try await d.fetchListing()
                        quotes = DirectTaiwanOpenAPISource.snapshots(from: listing, symbols: Set(tw))
                    } else {
                        quotes = []
                    }
                    let n = try book.applyQuotes(quotes, fetchedAt: now())
                    report.updated += n
                    try book.markRefreshed(Self.twKey, at: now())
                } catch {
                    report.errors.append("台股行情：\(error)")
                }
            } else {
                report.skippedSources.append(Self.twKey)
            }
        }

        if !us.isEmpty, let f = finnhub {
            if due(Self.usKey, interval: minInterval, force: force) {
                let r = await f.fetch(usSymbols: us)
                report.errors += r.errors
                do {
                    let n = try book.applyQuotes(r.quotes, fetchedAt: now())
                    report.updated += n
                    if !r.quotes.isEmpty { try book.markRefreshed(Self.usKey, at: now()) }
                } catch {
                    report.errors.append("美股行情：\(error)")
                }
            } else {
                report.skippedSources.append(Self.usKey)
            }
        }
        report.finishedAt = now()
        return report
    }
}
