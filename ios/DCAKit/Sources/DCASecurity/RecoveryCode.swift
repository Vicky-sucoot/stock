import Foundation

/// 可注入的亂數來源；正式環境用系統的密碼學安全亂數（SystemRandomNumberGenerator）。
public protocol SecureRandom {
    mutating func bytes(_ count: Int) -> [UInt8]
}

public struct SystemSecureRandom: SecureRandom {
    public init() {}
    public mutating func bytes(_ count: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) }
    }
}

/// 復原碼：20 個 Crockford Base32 字元（100 bits），每 4 字一組顯示（docs/10 §2）。
public struct RecoveryCode: Equatable, CustomStringConvertible {
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let length = 20
    public static let groupSize = 4
    public static var groupCount: Int { length / groupSize }

    /// 正規化後的 20 字元（不含連字號）
    public let normalized: String

    public init?(_ input: String) {
        guard let n = RecoveryCode.normalize(input), n.count == RecoveryCode.length else { return nil }
        normalized = n
    }

    /// 由 20 個隨機位元組產生；每個位元組取低 5 bits（32 種值均勻分布）。
    public static func from(randomBytes: [UInt8]) -> RecoveryCode {
        precondition(randomBytes.count == length)
        let chars = randomBytes.map { alphabet[Int($0 & 31)] }
        return RecoveryCode(String(chars))!
    }

    public var groups: [String] {
        let a = Array(normalized)
        return stride(from: 0, to: a.count, by: RecoveryCode.groupSize).map { String(a[$0..<$0 + RecoveryCode.groupSize]) }
    }

    /// 顯示格式：7K3M-QX9P-2HVD-R8TN-W4CJ
    public var description: String { groups.joined(separator: "-") }

    /// 不分大小寫；去除空白與連字號；O→0、I/L→1（Crockford 規則）。含其他字元時回傳 nil。
    public static func normalize(_ input: String) -> String? {
        var out = ""
        for ch in input.uppercased() {
            switch ch {
            case "-", " ", "\t", "\n": continue
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default:
                guard alphabet.contains(ch) else { return nil }
                out.append(ch)
            }
        }
        return out
    }
}
