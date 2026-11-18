import Foundation
import LocalAuthentication

/// Face ID（選用，預設關閉；docs/10 §7）。只當作解鎖捷徑，不能用來重設密碼。
enum Biometrics {
    static var isAvailable: Bool {
        var error: NSError?
        let ctx = LAContext()
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) && ctx.biometryType == .faceID
    }

    /// 生物辨識資料的版本；使用者新增或移除臉部資料時會改變
    static var domainState: Data? {
        let ctx = LAContext()
        var error: NSError?
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return ctx.evaluatedPolicyDomainState
    }

    static func authenticate() async -> Bool {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "輸入 App 密碼"
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "解鎖定期定額 App")
        } catch {
            return false
        }
    }
}
