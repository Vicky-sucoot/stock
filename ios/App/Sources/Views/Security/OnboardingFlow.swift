import DCASecurity
import SwiftUI

/// 首次啟動（docs/03 §4.1）：說明 → 設定密碼 → 顯示並核對復原碼 → 資料保存確認 → Face ID（選用）→ 第一個投資組合。
struct OnboardingFlow: View {
    enum Step { case welcome, passcode, confirmPasscode, recovery, faceID, firstPortfolio }

    @EnvironmentObject var model: AppModel
    @State private var step: Step = .welcome
    @State private var firstPin = ""
    @State private var pending: PendingCredentials?
    @State private var message: String?
    @State private var portfolioName = "我的投資組合"

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .welcome: welcome
                case .passcode:
                    PasscodePad(title: "設定 4 位數 App 密碼", subtitle: message ?? "請避免 0000、1234 這類組合") { pin in
                        do {
                            try PasscodeManager.validate(pin)
                            firstPin = pin
                            message = nil
                            step = .confirmPasscode
                        } catch {
                            message = SecurityText.describe(error)
                        }
                    }
                case .confirmPasscode:
                    PasscodePad(title: "再輸入一次", subtitle: message) { pin in
                        do {
                            pending = try model.passcode.beginSetup(passcode: firstPin, confirm: pin)
                            message = nil
                            step = .recovery
                        } catch {
                            message = SecurityText.describe(error)
                            step = .passcode
                        }
                    }
                case .recovery:
                    if let p = pending {
                        RecoveryCodeConfirmView(credentials: p, title: "你的復原碼", requireDataLossAck: true) { answers in
                            do {
                                try model.passcode.completeSetup(p, challengeAnswers: answers, dataLossAcknowledged: true)
                                step = Biometrics.isAvailable ? .faceID : .firstPortfolio
                                return nil
                            } catch {
                                return SecurityText.describe(error)
                            }
                        }
                    }
                case .faceID: faceID
                case .firstPortfolio: firstPortfolio
                }
            }
            .navigationTitle("開始使用")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("定期定額投資管理").font(.largeTitle.bold())
                Text("這個 App 用來規劃與記錄你的定期定額投資。")
                VStack(alignment: .leading, spacing: 8) {
                    Label("不連接券商、不下單、不會自動扣款", systemImage: "nosign")
                    Label("投資資料只存在這支 iPhone", systemImage: "iphone")
                    Label("不做 iCloud 備份，也不提供匯出", systemImage: "icloud.slash")
                    Label("行情可能延遲；你可以隨時手動修改價格與匯率", systemImage: "clock")
                }
                .font(.callout)
                Text("本 App 提供的資訊不構成投資建議，不保證準確或獲利。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("下一步") { step = .passcode }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
    }

    private var faceID: some View {
        VStack(spacing: 20) {
            Image(systemName: "faceid").font(.system(size: 56))
            Text("要開啟 Face ID 解鎖嗎？").font(.title3.bold())
            Text("Face ID 只是解鎖捷徑；忘記密碼時仍需使用復原碼。之後可在設定中變更。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("開啟 Face ID") {
                Task {
                    if await Biometrics.authenticate() {
                        try? model.passcode.setFaceID(enabled: true, currentPasscode: firstPin, domainState: Biometrics.domainState)
                    }
                    step = .firstPortfolio
                }
            }
            .buttonStyle(.borderedProminent)
            Button("暫時不要") { step = .firstPortfolio }
        }
        .padding()
    }

    private var firstPortfolio: some View {
        Form {
            Section {
                TextField("名稱", text: $portfolioName)
            } header: { Text("建立第一個投資組合") } footer: { Text("之後可以再建立更多投資組合，例如「退休」「子女教育」。") }
            Button("完成") {
                if model.mutate({ try $0.createPortfolio(name: portfolioName) }) != nil {
                    firstPin = ""
                    model.didUnlock()
                }
            }
        }
    }
}

/// 顯示復原碼，並要求輸入其中兩組核對（設定、重設、重新產生共用；docs/10 §2）。
struct RecoveryCodeConfirmView: View {
    let credentials: PendingCredentials
    let title: String
    var requireDataLossAck = false
    /// 回傳錯誤訊息；nil 代表成功
    let onConfirm: ([Int: String]) -> String?

    @State private var revealed = true
    @State private var answers: [Int: String] = [:]
    @State private var acknowledged = false
    @State private var message: String?

    var body: some View {
        Form {
            if revealed {
                Section {
                    Text(credentials.recoveryCode.description)
                        .font(.title3.monospaced().bold())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } header: { Text(title) } footer: {
                    Text("復原碼只會顯示這一次。建議抄在紙上並妥善保存，不要只存在這支手機裡。忘記 App 密碼時，需要用它重設密碼。")
                }
                Button("我已抄好，下一步") { revealed = false }
            } else {
                Section {
                    ForEach(credentials.challengeGroups, id: \.self) { g in
                        TextField("第 \(g + 1) 組（4 個字元）", text: Binding(get: { answers[g] ?? "" }, set: { answers[g] = $0 }))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    }
                } header: { Text("核對復原碼") } footer: { Text("請輸入你抄下的復原碼中指定的兩組。") }
                if requireDataLossAck {
                    Section {
                        Toggle(isOn: $acknowledged) {
                            Text("我了解：資料只存在這支手機，不做備份也不匯出。換手機、刪除 App，或同時遺失密碼與復原碼時，資料無法找回。")
                                .font(.footnote)
                        }
                    }
                }
                if let message { Section { Text(message).foregroundStyle(.red) } }
                Button("確認") { message = onConfirm(answers) }
                    .disabled(requireDataLossAck && !acknowledged)
                Button("再看一次復原碼") { revealed = true }
            }
        }
    }
}
