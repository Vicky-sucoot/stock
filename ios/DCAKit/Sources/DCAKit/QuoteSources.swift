import DCACore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum QuoteSourceError: Error, Equatable {
    case http(Int)
    case invalidResponse(String)
}

/// 可替換的 HTTP 介面（測試用假資料；App 用 URLSession）。
public protocol HTTPTransport {
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int)
}

public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    /// 通用識別字串，不含任何個人資訊
    public static let userAgent = "DCAApp/0.1"

    public init(timeout: TimeInterval = 30) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept": "application/json"]
        session = URLSession(configuration: cfg)
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: req) { data, resp, err in
                if let err = err { cont.resume(throwing: err); return }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                cont.resume(returning: (data ?? Data(), status))
            }.resume()
        }
    }
}

/// 官方 OpenAPI 欄位解析（與後端 dca_backend/parsing.py 相同規則）。
public enum TaiwanParsing {
    /// 民國年 YYYMMDD → 西元
    public static func rocDate(_ s: String?) -> LocalDate? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), (6...7).contains(s.count), s.allSatisfy(\.isNumber),
              let v = Int(s) else { return nil }
        let y = v / 10000 + 1911, m = (v / 100) % 100, d = v % 100
        guard (1...12).contains(m), d >= 1, d <= LocalDate.daysInMonth(year: y, month: m) else { return nil }
        return LocalDate(y, m, d)
    }

    /// 官方以 "----"、"--"、空字串等表示無資料（實測：TPEx 未成交為 "----"，TWSE 為空字串）。
    public static func decimal(_ s: String?) -> Decimal? {
        guard let raw = s else { return nil }
        let t = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        if t.isEmpty || t.allSatisfy({ $0 == "-" }) { return nil }
        guard t.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return Decimal(string: t, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// 欄位名稱去除空白（實測有 "主旨 " 等）
    public static func normKeys(_ row: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in row {
            let key = k.filter { !$0.isWhitespace }
            if let s = v as? String { out[key] = s }
        }
        return out
    }
}

public struct TaiwanListing: Equatable {
    public var symbol: String
    public var name: String
    public var board: String
    public var close: Decimal?
    public var dataDate: LocalDate?
}

/// 免費方案的預設來源：App 直接呼叫證交所與櫃買中心 OpenAPI（docs/07；尚未部署後端時使用）。
/// 兩個清單各約 300 KB，所以由 RefreshCoordinator 控制頻率（預設至少間隔 6 小時）。
public final class DirectTaiwanOpenAPISource {
    public static let twseURL = URL(string: "https://openapi.twse.com.tw/v1/exchangeReport/STOCK_DAY_ALL")!
    public static let tpexURL = URL(string: "https://www.tpex.org.tw/openapi/v1/tpex_mainboard_quotes")!
    static let twseAttribution = "資料來源：臺灣證券交易所 OpenAPI，依政府資料開放授權條款提供"
    static let tpexAttribution = "資料來源：證券櫃檯買賣中心 OpenAPI，依政府資料開放授權條款提供"

    private let transport: HTTPTransport

    public init(transport: HTTPTransport) { self.transport = transport }

    private func rows(_ url: URL) async throws -> [[String: String]] {
        let (data, status) = try await transport.get(url, headers: [:])
        guard status == 200 else { throw QuoteSourceError.http(status) }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw QuoteSourceError.invalidResponse(url.host ?? "")
        }
        return arr.map(TaiwanParsing.normKeys)
    }

    /// 上市與上櫃的完整清單（也用於離線搜尋標的）。
    public func fetchListing() async throws -> [TaiwanListing] {
        var out: [TaiwanListing] = []
        for r in try await rows(Self.twseURL) {
            guard let sym = r["Code"], let name = r["Name"] else { continue }
            out.append(TaiwanListing(symbol: sym, name: name, board: "TWSE",
                                     close: TaiwanParsing.decimal(r["ClosingPrice"]), dataDate: TaiwanParsing.rocDate(r["Date"])))
        }
        for r in try await rows(Self.tpexURL) {
            guard let sym = r["SecuritiesCompanyCode"], let name = r["CompanyName"] else { continue }
            out.append(TaiwanListing(symbol: sym, name: name, board: "TPEX",
                                     close: TaiwanParsing.decimal(r["Close"]), dataDate: TaiwanParsing.rocDate(r["Date"])))
        }
        return out
    }

    public static func snapshots(from listing: [TaiwanListing], symbols: Set<String>) -> [QuoteSnapshot] {
        listing.compactMap { l in
            guard symbols.contains(l.symbol), let c = l.close, c > 0, let d = l.dataDate else { return nil }
            let twse = l.board == "TWSE"
            return QuoteSnapshot(market: Market.tw, symbol: l.symbol, name: l.name, close: c, dataDate: d,
                                 sourceId: twse ? "TWSE_STOCK_DAY_ALL" : "TPEX_MAINBOARD_QUOTES",
                                 sourceURL: (twse ? twseURL : tpexURL).absoluteString,
                                 attribution: twse ? twseAttribution : tpexAttribution)
        }
    }
}

/// 後端部署後使用：GET /v1/quotes（backend/dca_backend/api.py）。
public final class BackendQuoteSource {
    private let baseURL: URL
    private let transport: HTTPTransport

    public init(baseURL: URL, transport: HTTPTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    struct Response: Decodable {
        struct Quote: Decodable {
            let symbol: String
            let name: String
            let close: String
            let data_date: String
            let source_id: String
            let source_url: String
            let attribution: String
        }
        let quotes: [Quote]
        let missing: [String]
    }

    public func fetch(twSymbols: [String]) async throws -> [QuoteSnapshot] {
        guard !twSymbols.isEmpty else { return [] }
        var comps = URLComponents(url: baseURL.appendingPathComponent("v1/quotes"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "symbols", value: twSymbols.map { "TW:\($0)" }.joined(separator: ","))]
        let (data, status) = try await transport.get(comps.url!, headers: [:])
        guard status == 200 else { throw QuoteSourceError.http(status) }
        let r = try JSONDecoder().decode(Response.self, from: data)
        return r.quotes.compactMap { q in
            guard let close = Dec(string: q.close)?.value, let d = LocalDate(iso: q.data_date) else { return nil }
            let sym = q.symbol.split(separator: ":").last.map(String.init) ?? q.symbol
            return QuoteSnapshot(market: Market.tw, symbol: sym, name: q.name, close: close, dataDate: d,
                                 sourceId: q.source_id, sourceURL: q.source_url, attribution: q.attribution)
        }
    }
}

/// 美股：使用者在設定頁輸入「自己的」Finnhub 個人 API 金鑰，由 App 直接呼叫（docs/01 R2-4）。
/// Finnhub 條款限個人用途、不得再散布，所以不經後端轉發。回應欄位（c、t）依官方文件慣例，**待上線前查核**。
public final class FinnhubQuoteSource {
    static let base = "https://finnhub.io/api/v1/quote"
    private let apiKey: String
    private let transport: HTTPTransport

    public init(apiKey: String, transport: HTTPTransport) {
        self.apiKey = apiKey
        self.transport = transport
    }

    struct Quote: Decodable {
        let c: Double?
        let t: Int?
    }

    public func fetch(usSymbols: [String]) async -> (quotes: [QuoteSnapshot], errors: [String]) {
        var quotes: [QuoteSnapshot] = []
        var errors: [String] = []
        for sym in usSymbols {
            var comps = URLComponents(string: Self.base)!
            comps.queryItems = [URLQueryItem(name: "symbol", value: sym)]
            do {
                // 金鑰放在標頭，不放在網址，避免出現在記錄中
                let (data, status) = try await transport.get(comps.url!, headers: ["X-Finnhub-Token": apiKey])
                guard status == 200 else { throw QuoteSourceError.http(status) }
                let q = try JSONDecoder().decode(Quote.self, from: data)
                guard let c = q.c, c > 0, let t = q.t, t > 0,
                      let close = Decimal(string: String(c), locale: Locale(identifier: "en_US_POSIX")) else {
                    errors.append("US:\(sym) 無資料")
                    continue
                }
                let day = try marketToday(market: Market.us, now: Date(timeIntervalSince1970: TimeInterval(t)))
                quotes.append(QuoteSnapshot(market: Market.us, symbol: sym, close: close, dataDate: day,
                                            sourceId: "FINNHUB_QUOTE", sourceURL: Self.base,
                                            attribution: "資料來源：Finnhub（使用者自備個人 API 金鑰）"))
            } catch {
                errors.append("US:\(sym) \(error)")
            }
        }
        return (quotes, errors)
    }
}
