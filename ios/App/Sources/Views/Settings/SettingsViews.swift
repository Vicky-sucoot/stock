import DCACore
import DCAKit
import DCASecurity
import SwiftUI

/// 手動設定價格、淨值或匯率（docs/05 §3）：持續有效，直到使用者再次修改或改回自動。
struct ManualValueSheet: View {
    enum Kind {
        case price(Instrument)
        case fx(String)
    }

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let kind: Kind
    @State private var value = ""
    @State private var date = Date()
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DecimalField(title: label, text: $value)
                    DatePicker("生效日", selection: $date, displayedComponents: .date)
                    TextField("備註（選填）", text: $note)
                } footer: {
                    Text("手動值會一直沿用，自動更新不會覆蓋；之後可再次修改或改回自動。月損益圖中，生效日之後的月份都使用此值。")
                }
                if isManual {
                    Button("改回自動") {
                        if model.mutate({ try $0.revertToAuto(key: key) }) != nil { dismiss() }
                    }
                }
            }
            .navigationTitle("手動設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("儲存") { save() }.disabled(Fmt.decimal(value) == nil) }
            }
            .onAppear {
                if let o = model.book.activeOverride(key: key) { value = o.value.description }
            }
        }
    }

    private var key: String {
        switch kind {
        case .price(let i): return i.id.uuidString
        case .fx(let c): return PortfolioBook.fxKey(c)
        }
    }

    private var label: String {
        switch kind {
        case .price(let i): return "\(i.symbol) 價格（\(i.currency)）"
        case .fx(let c): return "1 \(c) = ? TWD"
        }
    }

    private var isManual: Bool { model.book.activeOverride(key: key) != nil }

    private func save() {
        guard let v = Fmt.decimal(value) else { return }
        let iso = LocalDate(date: date).iso
        let n = note.isEmpty ? nil : note
        let ok: Void?
        switch kind {
        case .price(let i): ok = model.mutate { try $0.setManualPrice(instrumentId: i.id, value: v, effectiveDate: iso, note: n) }
        case .fx(let c): ok = model.mutate { try $0.setManualFx(currency: c, value: v, effectiveDate: iso, note: n) }
        }
        if ok != nil { dismiss() }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var apiKey = ""
    @State private var regenerating = false
    @State private var faceIDPrompt = false
    @State private var pin = ""
    @State private var wipePrompt = false
    @State private var wipeText = ""

    var body: some View {
        let state = try? model.passcode.loadState()
        Form {
            Section("安全") {
                Button("重新產生復原碼") { regenerating = true }
                if Biometrics.isAvailable {
                    Toggle("使用 Face ID 解鎖", isOn: Binding(get: { state?.faceIDEnabled == true }, set: { _ in faceIDPrompt = true }))
                }
                Picker("離開多久後需重新解鎖", selection: Binding(
                    get: { state?.relockAfterSeconds ?? 60 },
                    set: { try? model.passcode.setRelockAfter(seconds: $0); model.objectWillChange.send() })) {
                    Text("立即").tag(0)
                    Text("1 分鐘").tag(60)
                    Text("5 分鐘").tag(300)
                }
            }
            Section {
                SecureField(model.usApiKey == nil ? "Finnhub API 金鑰" : "已設定（輸入新值可取代）", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("儲存金鑰") { model.usApiKey = apiKey; apiKey = "" }.disabled(apiKey.isEmpty)
                if model.usApiKey != nil { Button("移除金鑰", role: .destructive) { model.usApiKey = nil } }
            } header: { Text("美股行情（選用）") } footer: {
                Text("請使用你自己申請的個人金鑰。金鑰只存在這支 iPhone 的 Keychain，由 App 直接查詢，不經過任何伺服器。")
            }
            Section("資料來源與聲明") {
                NavigationLink("資料來源") { SourcesView() }
                Text("本 App 只用於規劃與記錄，不連接券商、不下單、不扣款。所提供的資訊不構成投資建議，不保證準確或獲利。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text("資料只存在這支 iPhone，不做 iCloud 備份、不提供匯出。換手機、刪除 App，或同時遺失密碼與復原碼時，資料無法找回。")
                    .font(.footnote)
                Button("清除所有資料並重新開始", role: .destructive) { wipePrompt = true }
            } header: { Text("安全與資料") }
        }
        .navigationTitle("設定")
        .sheet(isPresented: $regenerating) { RegenerateRecoveryView() }
        .alert("輸入 App 密碼以變更 Face ID", isPresented: $faceIDPrompt) {
            SecureField("App 密碼", text: $pin)
            Button("確定") { toggleFaceID(enable: state?.faceIDEnabled != true) }
            Button("取消", role: .cancel) { pin = "" }
        }
        .alert("清除所有資料", isPresented: $wipePrompt) {
            TextField("請輸入「\(PasscodeManager.wipeConfirmationText)」", text: $wipeText)
            Button("清除", role: .destructive) {
                if !model.wipeEverything(confirmation: wipeText) { model.errorMessage = "確認文字不正確，未清除任何資料" }
                wipeText = ""
            }
            Button("取消", role: .cancel) { wipeText = "" }
        } message: {
            Text("會刪除本機所有投資組合、計畫、交易與設定，且無法還原。")
        }
    }

    private func toggleFaceID(enable: Bool) {
        let p = pin
        pin = ""
        Task {
            if enable { guard await Biometrics.authenticate() else { return } }
            do {
                try model.passcode.setFaceID(enabled: enable, currentPasscode: p, domainState: Biometrics.domainState)
                model.objectWillChange.send()
            } catch {
                model.errorMessage = SecurityText.describe(error)
            }
        }
    }
}

struct RegenerateRecoveryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pending: PendingCredentials?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if let p = pending {
                    RecoveryCodeConfirmView(credentials: p, title: "新的復原碼") { answers in
                        do {
                            try model.passcode.completeRegenerateRecoveryCode(p, challengeAnswers: answers)
                            dismiss()
                            return nil
                        } catch {
                            return SecurityText.describe(error)
                        }
                    }
                } else {
                    PasscodePad(title: "輸入目前的 App 密碼", subtitle: message ?? "完成後舊的復原碼會立即失效") { pin in
                        do {
                            pending = try model.passcode.beginRegenerateRecoveryCode(currentPasscode: pin)
                        } catch {
                            message = SecurityText.describe(error)
                        }
                    }
                }
            }
            .navigationTitle("重新產生復原碼")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

struct SourcesView: View {
    var body: some View {
        List {
            Section("台股與台灣 ETF 收盤價") {
                Text("臺灣證券交易所 OpenAPI（上市個股日成交資訊）")
                Text("證券櫃檯買賣中心 OpenAPI（上櫃股票收盤行情）")
                Text("依政府資料開放授權條款提供；官方資料可能延遲 1 個交易日以上。")
                Link("政府資料開放授權條款", destination: URL(string: "https://data.gov.tw/license")!)
            }
            Section("美股") { Text("Finnhub（使用你自己的個人 API 金鑰；未設定時請手動輸入）") }
            Section("日股、基金、匯率") { Text("目前沒有已確認授權的免費自動來源，請手動輸入。") }
        }
        .navigationTitle("資料來源")
    }
}
