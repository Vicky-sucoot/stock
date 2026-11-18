import DCASecurity
import SwiftUI

struct LockScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var message: String?
    @State private var lockedFor = 0
    @State private var busy = false
    @State private var showRecovery = false
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                PasscodePad(title: "輸入 App 密碼",
                            subtitle: lockedFor > 0 ? "請於 \(lockedFor) 秒後再試" : message,
                            disabled: busy || lockedFor > 0) { pin in unlock(pin) }
                if faceIDEnabled {
                    Button { Task { await tryFaceID() } } label: { Label("使用 Face ID", systemImage: "faceid") }
                        .padding(.bottom, 8)
                }
                Button("忘記密碼？使用復原碼") { showRecovery = true }
                    .font(.footnote)
                Spacer()
            }
            .navigationDestination(isPresented: $showRecovery) { RecoveryResetView() }
        }
        .onAppear {
            lockedFor = model.passcode.lockRemaining()
            if faceIDEnabled { Task { await tryFaceID() } }
        }
        .onReceive(timer) { _ in if lockedFor > 0 { lockedFor = model.passcode.lockRemaining() } }
    }

    private var faceIDEnabled: Bool {
        (try? model.passcode.loadState())?.faceIDEnabled == true && Biometrics.isAvailable
    }

    private func unlock(_ pin: String) {
        busy = true
        let mgr = model.passcode
        Task {
            do {
                try await background { try mgr.unlock(pin) }
                model.didUnlock()
            } catch PasscodeError.wrongPasscode(let n) {
                message = n < 5 ? "密碼錯誤（第 \(n) 次）" : "密碼錯誤"
                lockedFor = mgr.lockRemaining()
            } catch PasscodeError.locked(let s) {
                lockedFor = s
            } catch {
                message = "\(error)"
            }
            busy = false
        }
    }

    private func tryFaceID() async {
        // 生物辨識資料變更時自動停用（docs/10 §7）
        if (try? model.passcode.checkBiometricDomain(current: Biometrics.domainState)) == true {
            message = "Face ID 資料已變更，已停用 Face ID，請輸入密碼"
            return
        }
        guard lockedFor == 0, await Biometrics.authenticate() else { return }
        if (try? model.passcode.biometricUnlockSucceeded()) != nil { model.didUnlock() }
    }
}

/// 用復原碼重設密碼：投資資料完全不動，並產生新的復原碼（docs/10 §5）。
struct RecoveryResetView: View {
    @EnvironmentObject var model: AppModel
    @State private var code = ""
    @State private var newPin = ""
    @State private var confirmPin = ""
    @State private var pending: PendingCredentials?
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        Group {
            if let p = pending {
                RecoveryCodeConfirmView(credentials: p, title: "新的復原碼") { answers in
                    do {
                        try model.passcode.completeRecovery(p, challengeAnswers: answers)
                        model.didUnlock()
                        return nil
                    } catch {
                        return "驗證失敗，請再核對一次"
                    }
                }
            } else {
                Form {
                    Section {
                        TextField("例如 7K3M-QX9P-2HVD-R8TN-W4CJ", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    } header: { Text("復原碼") } footer: {
                        Text("重設密碼不會刪除或變更任何投資資料。完成後會產生新的復原碼，舊的復原碼立即失效。")
                    }
                    Section("新的 4 位數密碼") {
                        SecureField("新密碼", text: $newPin).keyboardType(.numberPad)
                        SecureField("再輸入一次", text: $confirmPin).keyboardType(.numberPad)
                    }
                    if let message { Section { Text(message).foregroundStyle(.red) } }
                    Button(busy ? "驗證中…" : "驗證並繼續") { verify() }
                        .disabled(busy || code.isEmpty || newPin.count != 4)
                }
            }
        }
        .navigationTitle("重設密碼")
    }

    private func verify() {
        busy = true
        let mgr = model.passcode
        let (c, p1, p2) = (code, newPin, confirmPin)
        Task {
            do {
                pending = try await background { try mgr.beginRecovery(recoveryCode: c, newPasscode: p1, confirm: p2) }
                message = nil
            } catch {
                message = SecurityText.describe(error)
            }
            busy = false
        }
    }
}

enum SecurityText {
    static func describe(_ error: Error) -> String {
        switch error as? PasscodeError {
        case .notFourDigits: return "密碼需為 4 位數字"
        case .tooSimple: return "密碼太簡單（例如 0000、1234），請換一組"
        case .mismatch: return "兩次輸入的密碼不同"
        case .wrongRecoveryCode(let n): return "復原碼不正確（第 \(n) 次）"
        case .invalidRecoveryCodeFormat: return "復原碼格式不正確（應為 20 個英數字）"
        case .locked(let s): return "嘗試次數過多，請於 \(s) 秒後再試"
        case .wrongPasscode: return "密碼錯誤"
        case .challengeFailed: return "復原碼核對失敗"
        case .dataLossNotAcknowledged: return "請先勾選資料保存說明"
        default: return "\(error)"
        }
    }
}
