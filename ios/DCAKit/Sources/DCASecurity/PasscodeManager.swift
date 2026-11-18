import Foundation

/// 密碼雜湊等機密的儲存介面。App 用 Keychain（ThisDeviceOnly）；測試用記憶體。
public protocol SecretStore: AnyObject {
    func read(_ key: String) throws -> Data?
    func write(_ key: String, _ value: Data) throws
    func delete(_ key: String) throws
}

public final class InMemorySecretStore: SecretStore {
    public private(set) var items: [String: Data] = [:]
    public init() {}
    public func read(_ key: String) throws -> Data? { items[key] }
    public func write(_ key: String, _ value: Data) throws { items[key] = value }
    public func delete(_ key: String) throws { items[key] = nil }
}

public enum PasscodeError: Error, Equatable {
    case notFourDigits
    case tooSimple
    case mismatch
    case notConfigured
    case alreadyConfigured
    case challengeFailed
    case dataLossNotAcknowledged
    case locked(remainingSeconds: Int)
    case wrongPasscode(failedCount: Int)
    case wrongRecoveryCode(failedCount: Int)
    case invalidRecoveryCodeFormat
}

/// 儲存在 Keychain 的安全狀態（不含任何投資資料）。
public struct SecurityState: Codable, Equatable {
    public var version = 1
    public var iterations: Int
    public var pinSalt: [UInt8]
    public var pinHash: [UInt8]
    public var recoverySalt: [UInt8]
    public var recoveryHash: [UInt8]
    public var pinLock = LockState()
    public var recoveryLock = LockState()
    public var faceIDEnabled = false
    public var biometricDomainState: Data?
    public var dataLossAcknowledgedAt: Date?
    /// 回到前景超過此秒數需重新解鎖（0、60、300）
    public var relockAfterSeconds: Int = 60
}

/// 設定或重設時的暫存資料：新密碼、新復原碼與驗證題目。完成前不會寫入任何東西。
public struct PendingCredentials {
    public let passcode: String
    public let recoveryCode: RecoveryCode
    /// 要求使用者輸入的復原碼組別（0 起算，兩組不重複）
    public let challengeGroups: [Int]
}

/// 4 位數密碼與復原碼（docs/10）。
/// 這個類別完全不接觸投資資料，所以「重設密碼」在結構上不可能刪除資料。
public final class PasscodeManager {
    public static let stateKey = "security.state.v1"
    public static let productionIterations = 600_000

    private let store: SecretStore
    private let clock: SecurityClock
    private var rng: SecureRandom
    private let iterations: Int

    public init(store: SecretStore, clock: SecurityClock = SystemSecurityClock(),
                rng: SecureRandom = SystemSecureRandom(), iterations: Int = PasscodeManager.productionIterations) {
        self.store = store
        self.clock = clock
        self.rng = rng
        self.iterations = iterations
    }

    // MARK: - 狀態

    public func loadState() throws -> SecurityState? {
        guard let data = try store.read(Self.stateKey) else { return nil }
        return try JSONDecoder().decode(SecurityState.self, from: data)
    }

    private func save(_ state: SecurityState) throws {
        try store.write(Self.stateKey, try JSONEncoder().encode(state))
    }

    private func requireState() throws -> SecurityState {
        guard let s = try loadState() else { throw PasscodeError.notConfigured }
        return s
    }

    public var isConfigured: Bool { (try? loadState()) != nil }

    // MARK: - 密碼規則

    /// 必須是 4 位數字；拒絕同一數字（0000）與連續遞增或遞減（1234、9876）。
    public static func validate(_ pin: String) throws {
        let digits = pin.compactMap { $0.wholeNumberValue }
        guard pin.count == 4, digits.count == 4, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw PasscodeError.notFourDigits
        }
        if Set(digits).count == 1 { throw PasscodeError.tooSimple }
        let steps = zip(digits.dropFirst(), digits).map { $0 - $1 }
        if steps.allSatisfy({ $0 == 1 }) || steps.allSatisfy({ $0 == -1 }) { throw PasscodeError.tooSimple }
    }

    private func hash(_ secret: String, salt: [UInt8]) -> [UInt8] {
        PBKDF2.sha256(password: Array(secret.utf8), salt: salt, iterations: iterations)
    }

    private func newCredentials(_ pin: String, confirm: String) throws -> PendingCredentials {
        try Self.validate(pin)
        guard pin == confirm else { throw PasscodeError.mismatch }
        let code = RecoveryCode.from(randomBytes: rng.bytes(RecoveryCode.length))
        var groups = Set<Int>()
        while groups.count < 2 {
            groups.insert(Int(rng.bytes(1)[0]) % RecoveryCode.groupCount)
        }
        return PendingCredentials(passcode: pin, recoveryCode: code, challengeGroups: groups.sorted())
    }

    private func checkChallenge(_ p: PendingCredentials, answers: [Int: String]) throws {
        let groups = p.recoveryCode.groups
        for g in p.challengeGroups {
            guard let a = answers[g], RecoveryCode.normalize(a) == groups[g] else { throw PasscodeError.challengeFailed }
        }
    }

    private func credentialFields(_ p: PendingCredentials) -> (pinSalt: [UInt8], pinHash: [UInt8], rcSalt: [UInt8], rcHash: [UInt8]) {
        let ps = rng.bytes(16), rs = rng.bytes(16)
        return (ps, hash(p.passcode, salt: ps), rs, hash(p.recoveryCode.normalized, salt: rs))
    }

    // MARK: - 首次設定（docs/10 §2）

    public func beginSetup(passcode: String, confirm: String) throws -> PendingCredentials {
        if isConfigured { throw PasscodeError.alreadyConfigured }
        return try newCredentials(passcode, confirm: confirm)
    }

    /// 復原碼驗證通過、且使用者勾選資料保存說明後，才寫入。
    public func completeSetup(_ p: PendingCredentials, challengeAnswers: [Int: String], dataLossAcknowledged: Bool) throws {
        if isConfigured { throw PasscodeError.alreadyConfigured }
        try checkChallenge(p, answers: challengeAnswers)
        guard dataLossAcknowledged else { throw PasscodeError.dataLossNotAcknowledged }
        let f = credentialFields(p)
        var s = SecurityState(iterations: iterations, pinSalt: f.pinSalt, pinHash: f.pinHash,
                              recoverySalt: f.rcSalt, recoveryHash: f.rcHash)
        s.dataLossAcknowledgedAt = clock.now
        try save(s)
    }

    // MARK: - 解鎖（docs/10 §4）

    public func lockRemaining() -> Int {
        guard let s = try? loadState() else { return 0 }
        return Int(s.pinLock.remaining(clock: clock).rounded(.up))
    }

    public func unlock(_ pin: String) throws {
        var s = try requireState()
        let remaining = s.pinLock.remaining(clock: clock)
        if remaining > 0 { throw PasscodeError.locked(remainingSeconds: Int(remaining.rounded(.up))) }
        let candidate = PBKDF2.sha256(password: Array(pin.utf8), salt: s.pinSalt, iterations: s.iterations)
        if PBKDF2.constantTimeEqual(candidate, s.pinHash) {
            s.pinLock.reset()
            try save(s)
            return
        }
        s.pinLock.recordFailure(clock: clock)
        try save(s)
        throw PasscodeError.wrongPasscode(failedCount: s.pinLock.failedCount)
    }

    // MARK: - 用復原碼重設密碼（docs/10 §5）

    /// 驗證復原碼；成功後回傳新的密碼與新的復原碼草稿（舊碼在 completeRecovery 時作廢）。
    public func beginRecovery(recoveryCode input: String, newPasscode: String, confirm: String) throws -> PendingCredentials {
        var s = try requireState()
        let remaining = s.recoveryLock.remaining(clock: clock)
        if remaining > 0 { throw PasscodeError.locked(remainingSeconds: Int(remaining.rounded(.up))) }
        guard let code = RecoveryCode(input) else { throw PasscodeError.invalidRecoveryCodeFormat }
        let candidate = PBKDF2.sha256(password: Array(code.normalized.utf8), salt: s.recoverySalt, iterations: s.iterations)
        guard PBKDF2.constantTimeEqual(candidate, s.recoveryHash) else {
            s.recoveryLock.recordFailure(clock: clock)
            try save(s)
            throw PasscodeError.wrongRecoveryCode(failedCount: s.recoveryLock.failedCount)
        }
        s.recoveryLock.reset()
        try save(s)
        return try newCredentials(newPasscode, confirm: confirm)
    }

    public func completeRecovery(_ p: PendingCredentials, challengeAnswers: [Int: String]) throws {
        try replaceCredentials(p, challengeAnswers: challengeAnswers)
    }

    /// 設定頁「重新產生復原碼」：需先輸入目前密碼。
    public func beginRegenerateRecoveryCode(currentPasscode: String) throws -> PendingCredentials {
        try unlock(currentPasscode)
        return try newCredentials(currentPasscode, confirm: currentPasscode)
    }

    public func completeRegenerateRecoveryCode(_ p: PendingCredentials, challengeAnswers: [Int: String]) throws {
        try replaceCredentials(p, challengeAnswers: challengeAnswers)
    }

    private func replaceCredentials(_ p: PendingCredentials, challengeAnswers: [Int: String]) throws {
        var s = try requireState()
        try checkChallenge(p, answers: challengeAnswers)
        let f = credentialFields(p)
        s.iterations = iterations
        s.pinSalt = f.pinSalt
        s.pinHash = f.pinHash
        s.recoverySalt = f.rcSalt
        s.recoveryHash = f.rcHash
        s.pinLock.reset()
        s.recoveryLock.reset()
        try save(s)
    }

    // MARK: - Face ID（選用，docs/10 §7）

    public func setFaceID(enabled: Bool, currentPasscode: String, domainState: Data?) throws {
        try unlock(currentPasscode)
        var s = try requireState()
        s.faceIDEnabled = enabled
        s.biometricDomainState = enabled ? domainState : nil
        try save(s)
    }

    /// 生物辨識資料變更時自動停用 Face ID；回傳是否因此停用。
    @discardableResult
    public func checkBiometricDomain(current: Data?) throws -> Bool {
        var s = try requireState()
        guard s.faceIDEnabled, s.biometricDomainState != current else { return false }
        s.faceIDEnabled = false
        s.biometricDomainState = nil
        try save(s)
        return true
    }

    /// Face ID 驗證成功後由 App 呼叫：視同解鎖成功，但不會重設密碼。
    public func biometricUnlockSucceeded() throws {
        var s = try requireState()
        guard s.faceIDEnabled else { throw PasscodeError.notConfigured }
        s.pinLock.reset()
        try save(s)
    }

    public func setRelockAfter(seconds: Int) throws {
        var s = try requireState()
        s.relockAfterSeconds = [0, 60, 300].contains(seconds) ? seconds : 60
        try save(s)
    }

    /// 「清除所有資料並重新開始」用：只清除安全狀態；投資資料由呼叫端另外清除。
    public static let wipeConfirmationText = "清除全部資料"

    public func wipeSecurityState(confirmation: String) throws -> Bool {
        guard confirmation == Self.wipeConfirmationText else { return false }
        try store.delete(Self.stateKey)
        return true
    }
}
