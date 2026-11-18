import Foundation

/// 時間來源：牆上時間（可被使用者改）與開機後經過的單調時間（不受改時間影響）。
public protocol SecurityClock {
    var now: Date { get }
    var uptime: TimeInterval { get }
}

public struct SystemSecurityClock: SecurityClock {
    public init() {}
    public var now: Date { Date() }
    public var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// 連續失敗的鎖定狀態（docs/10 §4）。不會因失敗次數而清除任何資料。
public struct LockState: Codable, Equatable {
    public var failedCount: Int = 0
    public var lockDuration: TimeInterval = 0
    public var lockStartWall: Date?
    public var lockStartUptime: TimeInterval?

    public init() {}

    /// 1–4 次不鎖；第 5 次 1 分鐘、第 6 次 5 分鐘、第 7 次 15 分鐘、之後每次 1 小時。
    public static func duration(forFailures n: Int) -> TimeInterval {
        switch n {
        case ..<5: return 0
        case 5: return 60
        case 6: return 300
        case 7: return 900
        default: return 3600
        }
    }

    /// 剩餘鎖定秒數；0 代表未鎖定。
    /// 同一次開機內用單調時間計算，改系統時間無法縮短鎖定；
    /// 重新開機後（uptime 變小）才改用牆上時間，且牆上時間倒退時視為鎖定剛開始。
    public func remaining(clock: SecurityClock) -> TimeInterval {
        guard lockDuration > 0, let startWall = lockStartWall, let startUp = lockStartUptime else { return 0 }
        let elapsed: TimeInterval
        if clock.uptime >= startUp {
            elapsed = clock.uptime - startUp
        } else {
            elapsed = max(0, clock.now.timeIntervalSince(startWall))
        }
        return max(0, lockDuration - elapsed)
    }

    public mutating func recordFailure(clock: SecurityClock) {
        failedCount += 1
        let d = LockState.duration(forFailures: failedCount)
        if d > 0 {
            lockDuration = d
            lockStartWall = clock.now
            lockStartUptime = clock.uptime
        }
    }

    public mutating func reset() { self = LockState() }
}
