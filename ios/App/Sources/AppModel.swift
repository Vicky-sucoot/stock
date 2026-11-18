import DCACore
import DCAKit
import DCASecurity
import Foundation
import SwiftUI

/// App 狀態：安全（PasscodeManager）與資料（PortfolioBook）分開管理。
/// 重設密碼只經過 PasscodeManager，結構上不可能動到投資資料（docs/10）。
@MainActor
final class AppModel: ObservableObject {
    enum Phase { case onboarding, locked, unlocked }

    @Published var phase: Phase
    @Published var book: PortfolioBook
    @Published var revision = 0  // 資料變動時遞增，讓畫面重新計算
    @Published var refreshing = false
    @Published var lastReport: RefreshReport?
    @Published var errorMessage: String?
    @Published var viewCurrency: String {
        didSet { UserDefaults.standard.set(viewCurrency, forKey: "viewCurrency") }
    }
    @Published var includeDividends: Bool {
        didSet { UserDefaults.standard.set(includeDividends, forKey: "includeDividends") }
    }
    @Published var listing: [TaiwanListing] = []

    let secrets: SecretStore
    let passcode: PasscodeManager
    private let transport = URLSessionTransport()
    private var backgroundedAt: Date?

    static let usApiKeyKey = "finnhub.apiKey"
    /// 後端部署後填入網址即改用後端；目前免費方案直接呼叫官方 OpenAPI
    static let backendURL: URL? = nil

    init() {
        let secrets = KeychainSecretStore()
        self.secrets = secrets
        passcode = PasscodeManager(store: secrets)
        do {
            book = try PortfolioBook(store: JSONFileDataStore(url: try JSONFileDataStore.defaultURL()))
        } catch {
            // 讀取失敗時不覆寫原檔：改用記憶體，並顯示錯誤讓使用者知道
            book = try! PortfolioBook(store: InMemoryDataStore())
            errorMessage = "無法讀取本機資料：\(error)"
        }
        viewCurrency = UserDefaults.standard.string(forKey: "viewCurrency") ?? "TWD"
        includeDividends = UserDefaults.standard.object(forKey: "includeDividends") as? Bool ?? true
        phase = passcode.isConfigured ? .locked : .onboarding
    }

    // MARK: - 鎖定

    func didUnlock() {
        phase = .unlocked
        Task { await afterUnlock() }
    }

    func afterUnlock() async {
        mutate { try $0.generatePending() }
        await refresh(force: false)
    }

    func scenePhaseChanged(_ p: ScenePhase) {
        switch p {
        case .background:
            backgroundedAt = Date()
        case .active:
            guard phase == .unlocked, let t = backgroundedAt else { return }
            let limit: Int = (try? passcode.loadState())?.relockAfterSeconds ?? 60
            if Date().timeIntervalSince(t) >= TimeInterval(limit) { phase = .locked }
            backgroundedAt = nil
        default:
            break
        }
    }

    // MARK: - 資料

    /// 所有修改都經過這裡：失敗時顯示錯誤，成功時通知畫面更新。
    @discardableResult
    func mutate<T>(_ body: (PortfolioBook) throws -> T) -> T? {
        do {
            let r = try body(book)
            revision += 1
            return r
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case BookError.invalidName(let m), BookError.invalidPlan(let m), BookError.invalidAmount(let m): return m
        case BookError.duplicateName: return "名稱已存在"
        case BookError.notFound: return "找不到資料"
        case BookError.invalidDate(let d): return "日期格式錯誤：\(d)"
        case BookError.ledger("OVERSELL"): return "賣出數量超過持有數量"
        case BookError.ledger(let code): return "交易資料不正確（\(code)）"
        case BookError.occurrenceNotPending: return "這一期已處理"
        default: return "\(error)"
        }
    }

    var usApiKey: String? {
        get {
            guard let data = try? secrets.read(Self.usApiKeyKey) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            if let v = newValue?.trimmingCharacters(in: .whitespaces), !v.isEmpty {
                try? secrets.write(Self.usApiKeyKey, Data(v.utf8))
            } else {
                try? secrets.delete(Self.usApiKeyKey)
            }
            objectWillChange.send()
        }
    }

    func refresh(force: Bool) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let rc = RefreshCoordinator(
            book: book,
            direct: Self.backendURL == nil ? DirectTaiwanOpenAPISource(transport: transport) : nil,
            backend: Self.backendURL.map { BackendQuoteSource(baseURL: $0, transport: transport) },
            finnhub: usApiKey.map { FinnhubQuoteSource(apiKey: $0, transport: transport) })
        lastReport = await rc.refresh(force: force)
        revision += 1
    }

    /// 搜尋台股標的用的清單（向官方 OpenAPI 取得一次後快取在記憶體）。
    func loadListingIfNeeded() async {
        guard listing.isEmpty else { return }
        if let l = try? await DirectTaiwanOpenAPISource(transport: transport).fetchListing() { listing = l }
    }

    // MARK: - 清除

    func wipeEverything(confirmation: String) -> Bool {
        guard (try? passcode.wipeSecurityState(confirmation: confirmation)) == true else { return false }
        try? secrets.delete(Self.usApiKeyKey)
        try? book.wipeAll()
        revision += 1
        phase = .onboarding
        return true
    }
}

/// PBKDF2 需要數百毫秒，在背景執行避免卡住畫面。
func background<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) { try work() }.value
}
