import Crypto
import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// PBKDF2-HMAC-SHA256（docs/10 §3）。Apple 平台使用 CommonCrypto（快）；其他平台用 swift-crypto 的 HMAC 實作。
public enum PBKDF2 {
    public static func sha256(password: [UInt8], salt: [UInt8], iterations: Int, keyLength: Int = 32) -> [UInt8] {
        precondition(iterations >= 1 && keyLength >= 1)
        #if canImport(CommonCrypto)
        var out = [UInt8](repeating: 0, count: keyLength)
        let status = password.withUnsafeBufferPointer { pw in
            salt.withUnsafeBufferPointer { s in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    UnsafeRawPointer(pw.baseAddress!).assumingMemoryBound(to: Int8.self), pw.count,
                    s.baseAddress, s.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                    &out, keyLength)
            }
        }
        precondition(status == Int32(kCCSuccess), "PBKDF2 failed")
        return out
        #else
        return portableSHA256(password: password, salt: salt, iterations: iterations, keyLength: keyLength)
        #endif
    }

    /// 與 CommonCrypto 等價的可攜實作（RFC 8018 §5.2）。
    static func portableSHA256(password: [UInt8], salt: [UInt8], iterations: Int, keyLength: Int) -> [UInt8] {
        let key = SymmetricKey(data: password)
        var result: [UInt8] = []
        var blockIndex: UInt32 = 1
        while result.count < keyLength {
            var message = salt
            message.append(contentsOf: [
                UInt8(truncatingIfNeeded: blockIndex >> 24), UInt8(truncatingIfNeeded: blockIndex >> 16),
                UInt8(truncatingIfNeeded: blockIndex >> 8), UInt8(truncatingIfNeeded: blockIndex),
            ])
            var u = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Array(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for i in 0..<t.count { t[i] ^= u[i] }
                }
            }
            result.append(contentsOf: t)
            blockIndex += 1
        }
        return Array(result.prefix(keyLength))
    }

    /// 常數時間比較，避免以回應時間推測雜湊內容。
    public static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
