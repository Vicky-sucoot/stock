import Foundation
import XCTest
@testable import DCASecurity

final class FakeClock: SecurityClock {
    var now: Date
    var uptime: TimeInterval
    init(now: Date = Date(timeIntervalSince1970: 1_800_000_000), uptime: TimeInterval = 1000) {
        self.now = now
        self.uptime = uptime
    }
    func advance(_ s: TimeInterval) {
        now = now.addingTimeInterval(s)
        uptime += s
    }
}

/// 可預測的亂數（只用於測試）
struct CountingRandom: SecureRandom {
    // SplitMix64：可重現、分布良好
    var state: UInt64 = 0x1234_5678
    mutating func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return UInt8(truncatingIfNeeded: z ^ (z >> 31))
        }
    }
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

final class PBKDF2Tests: XCTestCase {
    // 參考值由 Python hashlib.pbkdf2_hmac('sha256', ...) 計算
    func testVectors() {
        let pw = Array("password".utf8), salt = Array("salt".utf8)
        XCTAssertEqual(hex(PBKDF2.sha256(password: pw, salt: salt, iterations: 1)),
                       "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertEqual(hex(PBKDF2.sha256(password: pw, salt: salt, iterations: 2)),
                       "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        XCTAssertEqual(hex(PBKDF2.sha256(password: pw, salt: salt, iterations: 4096)),
                       "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    func testMultiBlockOutput() {
        let out = PBKDF2.portableSHA256(password: Array("passwordPASSWORDpassword".utf8),
                                        salt: Array("saltSALTsaltSALTsaltSALTsaltSALTsalt".utf8),
                                        iterations: 4096, keyLength: 40)
        XCTAssertEqual(hex(out), "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9")
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(PBKDF2.constantTimeEqual([1, 2, 3], [1, 2, 3]))
        XCTAssertFalse(PBKDF2.constantTimeEqual([1, 2, 3], [1, 2, 4]))
        XCTAssertFalse(PBKDF2.constantTimeEqual([1, 2], [1, 2, 3]))
    }
}

final class RecoveryCodeTests: XCTestCase {
    func testFormatAndNormalize() {
        let code = RecoveryCode.from(randomBytes: Array(0..<20))
        XCTAssertEqual(code.normalized.count, 20)
        XCTAssertEqual(code.groups.count, 5)
        XCTAssertEqual(code.description.split(separator: "-").count, 5)
        // 不分大小寫、可含連字號與空白；O→0、I/L→1
        XCTAssertEqual(RecoveryCode.normalize("ab-cd o i l"), "ABCD011")
        XCTAssertNil(RecoveryCode.normalize("ABCU"))  // U 不在 Crockford 字母表
        XCTAssertEqual(RecoveryCode(code.description.lowercased()), code)
        XCTAssertNil(RecoveryCode("TOO-SHORT"))
    }

    func testAllSymbolsReachable() {
        let code = RecoveryCode.from(randomBytes: (0..<20).map { UInt8($0 + 12) })
        XCTAssertTrue(code.normalized.allSatisfy { RecoveryCode.alphabet.contains($0) })
    }
}

final class LockStateTests: XCTestCase {
    func testDurations() {
        XCTAssertEqual((1...9).map { LockState.duration(forFailures: $0) }, [0, 0, 0, 0, 60, 300, 900, 3600, 3600])
    }

    func testSettingClockForwardDoesNotUnlockWithinSameBoot() {
        let clock = FakeClock()
        var s = LockState()
        for _ in 0..<5 { s.recordFailure(clock: clock) }
        XCTAssertEqual(s.remaining(clock: clock), 60)
        clock.now = clock.now.addingTimeInterval(86_400)  // T18：使用者把時間往後調
        XCTAssertEqual(s.remaining(clock: clock), 60)
        clock.uptime += 59
        XCTAssertEqual(s.remaining(clock: clock), 1)
        clock.uptime += 1
        XCTAssertEqual(s.remaining(clock: clock), 0)
    }

    func testAfterRebootUsesWallClockAndBackwardsClockKeepsLock() {
        let clock = FakeClock()
        var s = LockState()
        for _ in 0..<6 { s.recordFailure(clock: clock) }  // 5 分鐘
        clock.uptime = 10  // 重新開機
        clock.now = clock.now.addingTimeInterval(-3600)  // 時間往回調
        XCTAssertEqual(s.remaining(clock: clock), 300)
        clock.now = clock.now.addingTimeInterval(3600 + 120)
        XCTAssertEqual(s.remaining(clock: clock), 180)
    }
}

final class PasscodeManagerTests: XCTestCase {
    var store: InMemorySecretStore!
    var clock: FakeClock!
    var mgr: PasscodeManager!

    override func setUp() {
        store = InMemorySecretStore()
        clock = FakeClock()
        mgr = PasscodeManager(store: store, clock: clock, rng: CountingRandom(), iterations: 1000)
    }

    func answers(_ p: PendingCredentials) -> [Int: String] {
        Dictionary(uniqueKeysWithValues: p.challengeGroups.map { ($0, p.recoveryCode.groups[$0].lowercased()) })
    }

    @discardableResult
    func setup(_ pin: String = "2580") throws -> PendingCredentials {
        let p = try mgr.beginSetup(passcode: pin, confirm: pin)
        try mgr.completeSetup(p, challengeAnswers: answers(p), dataLossAcknowledged: true)
        return p
    }

    func testValidation() {
        for bad in ["123", "12345", "12a4", "１２３４"] {
            XCTAssertThrowsError(try PasscodeManager.validate(bad)) { XCTAssertEqual($0 as? PasscodeError, .notFourDigits, bad) }
        }
        for weak in ["0000", "1234", "6789", "9876", "3210"] {
            XCTAssertThrowsError(try PasscodeManager.validate(weak)) { XCTAssertEqual($0 as? PasscodeError, .tooSimple, weak) }
        }
        XCTAssertNoThrow(try PasscodeManager.validate("2580"))
        XCTAssertNoThrow(try PasscodeManager.validate("1357"))
    }

    func testSetupRequiresChallengeAndAcknowledgement() throws {
        XCTAssertThrowsError(try mgr.beginSetup(passcode: "2580", confirm: "2581")) { XCTAssertEqual($0 as? PasscodeError, .mismatch) }
        let p = try mgr.beginSetup(passcode: "2580", confirm: "2580")
        XCTAssertEqual(p.challengeGroups.count, 2)
        XCTAssertNotEqual(p.challengeGroups[0], p.challengeGroups[1])
        XCTAssertThrowsError(try mgr.completeSetup(p, challengeAnswers: [:], dataLossAcknowledged: true)) {
            XCTAssertEqual($0 as? PasscodeError, .challengeFailed)
        }
        XCTAssertThrowsError(try mgr.completeSetup(p, challengeAnswers: answers(p), dataLossAcknowledged: false)) {
            XCTAssertEqual($0 as? PasscodeError, .dataLossNotAcknowledged)
        }
        XCTAssertFalse(mgr.isConfigured)  // AC-21：未完成驗證前不寫入
        try mgr.completeSetup(p, challengeAnswers: answers(p), dataLossAcknowledged: true)
        XCTAssertTrue(mgr.isConfigured)
        XCTAssertNotNil(try mgr.loadState()?.dataLossAcknowledgedAt)
        XCTAssertThrowsError(try mgr.beginSetup(passcode: "1357", confirm: "1357"))
    }

    func testSecretsAreNotStoredInPlaintext() throws {
        let p = try setup()
        let blob = String(decoding: store.items[PasscodeManager.stateKey]!, as: UTF8.self)
        XCTAssertFalse(blob.contains(p.recoveryCode.normalized))
        XCTAssertFalse(blob.contains("2580"))
    }

    func testUnlockAndLockout() throws {
        try setup()
        XCTAssertNoThrow(try mgr.unlock("2580"))
        for i in 1...4 {
            XCTAssertThrowsError(try mgr.unlock("1111")) { XCTAssertEqual($0 as? PasscodeError, .wrongPasscode(failedCount: i)) }
        }
        XCTAssertThrowsError(try mgr.unlock("1111")) { XCTAssertEqual($0 as? PasscodeError, .wrongPasscode(failedCount: 5)) }
        // 鎖定中：連正確密碼也不接受
        XCTAssertThrowsError(try mgr.unlock("2580")) { XCTAssertEqual($0 as? PasscodeError, .locked(remainingSeconds: 60)) }
        clock.advance(60)
        XCTAssertNoThrow(try mgr.unlock("2580"))
        XCTAssertEqual(try mgr.loadState()?.pinLock.failedCount, 0)
    }

    func testRecoveryResetsPasscodeAndRotatesCode() throws {
        let original = try setup()
        XCTAssertThrowsError(try mgr.beginRecovery(recoveryCode: "0000-0000-0000-0000-0000", newPasscode: "1357", confirm: "1357")) {
            XCTAssertEqual($0 as? PasscodeError, .wrongRecoveryCode(failedCount: 1))
        }
        let p = try mgr.beginRecovery(recoveryCode: original.recoveryCode.description.lowercased(),
                                      newPasscode: "1357", confirm: "1357")
        XCTAssertNotEqual(p.recoveryCode, original.recoveryCode)
        // 驗證新復原碼前，舊密碼仍有效
        XCTAssertNoThrow(try mgr.unlock("2580"))
        try mgr.completeRecovery(p, challengeAnswers: answers(p))
        XCTAssertNoThrow(try mgr.unlock("1357"))
        XCTAssertThrowsError(try mgr.unlock("2580"))
        // AC-23：舊復原碼作廢
        XCTAssertThrowsError(try mgr.beginRecovery(recoveryCode: original.recoveryCode.description,
                                                   newPasscode: "2468", confirm: "2468"))
        XCTAssertNoThrow(try mgr.beginRecovery(recoveryCode: p.recoveryCode.description, newPasscode: "2468", confirm: "2468"))
    }

    func testRecoveryAttemptsAreLimitedSeparately() throws {
        try setup()
        for _ in 0..<5 {
            _ = try? mgr.beginRecovery(recoveryCode: "0000-0000-0000-0000-0000", newPasscode: "1357", confirm: "1357")
        }
        XCTAssertThrowsError(try mgr.beginRecovery(recoveryCode: "0000-0000-0000-0000-0000", newPasscode: "1357", confirm: "1357")) {
            XCTAssertEqual($0 as? PasscodeError, .locked(remainingSeconds: 60))
        }
        XCTAssertNoThrow(try mgr.unlock("2580"))  // 密碼的失敗計數獨立
    }

    func testRegenerateRecoveryCodeNeedsPasscode() throws {
        let original = try setup()
        XCTAssertThrowsError(try mgr.beginRegenerateRecoveryCode(currentPasscode: "1111"))
        let p = try mgr.beginRegenerateRecoveryCode(currentPasscode: "2580")
        try mgr.completeRegenerateRecoveryCode(p, challengeAnswers: answers(p))
        XCTAssertNoThrow(try mgr.unlock("2580"))
        XCTAssertThrowsError(try mgr.beginRecovery(recoveryCode: original.recoveryCode.description, newPasscode: "1357", confirm: "1357"))
    }

    func testFaceIDIsOptionalAndDisabledWhenBiometricsChange() throws {
        try setup()
        XCTAssertEqual(try mgr.loadState()?.faceIDEnabled, false)  // 預設關閉
        XCTAssertThrowsError(try mgr.biometricUnlockSucceeded())
        XCTAssertThrowsError(try mgr.setFaceID(enabled: true, currentPasscode: "1111", domainState: Data([1])))
        try mgr.setFaceID(enabled: true, currentPasscode: "2580", domainState: Data([1]))
        XCTAssertFalse(try mgr.checkBiometricDomain(current: Data([1])))
        XCTAssertTrue(try mgr.checkBiometricDomain(current: Data([2])))
        XCTAssertEqual(try mgr.loadState()?.faceIDEnabled, false)
    }

    func testWipeNeedsExactConfirmation() throws {
        try setup()
        XCTAssertFalse(try mgr.wipeSecurityState(confirmation: "清除"))
        XCTAssertTrue(mgr.isConfigured)
        XCTAssertTrue(try mgr.wipeSecurityState(confirmation: "清除全部資料"))
        XCTAssertFalse(mgr.isConfigured)
    }
}
