import Foundation
import CommonCrypto

struct TOTPVerifier {
    private let secret: [UInt8]
    private let timeStep: UInt64
    private let tolerance: Int

    init(secret: [UInt8] = Config.totpSecret,
         timeStep: UInt64 = Config.totpTimeStep,
         tolerance: Int = Config.totpTolerance) {
        self.secret = secret
        self.timeStep = timeStep
        self.tolerance = tolerance
    }

    /// Generate TOTP code for a given time step
    func generateCode(for counter: UInt64) -> UInt32 {
        // Convert counter to big-endian bytes
        var counterBE = counter.bigEndian
        let counterData = Data(bytes: &counterBE, count: 8)

        // Compute HMAC-SHA1
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        counterData.withUnsafeBytes { counterPtr in
            secret.withUnsafeBytes { secretPtr in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1),
                       secretPtr.baseAddress, secret.count,
                       counterPtr.baseAddress, 8,
                       &hash)
            }
        }

        // Dynamic truncation (RFC 6238)
        let offset = Int(hash[19] & 0x0F)
        let code = (UInt32(hash[offset] & 0x7F) << 24) |
                   (UInt32(hash[offset + 1]) << 16) |
                   (UInt32(hash[offset + 2]) << 8) |
                   UInt32(hash[offset + 3])

        return code % 1_000_000
    }

    /// Get current TOTP code
    func currentCode() -> UInt32 {
        let counter = UInt64(Date().timeIntervalSince1970) / timeStep
        return generateCode(for: counter)
    }

    /// Verify a TOTP code (with tolerance for clock drift)
    func verify(_ code: UInt32) -> Bool {
        let currentCounter = UInt64(Date().timeIntervalSince1970) / timeStep

        // Check current and adjacent time steps
        for offset in -tolerance...tolerance {
            let counter = UInt64(Int64(currentCounter) + Int64(offset))
            if generateCode(for: counter) == code {
                return true
            }
        }
        return false
    }

    /// Verify a code string from QR (format: "UNLOCK:123456")
    func verifyQRContent(_ content: String) -> Bool {
        guard content.hasPrefix("UNLOCK:") else { return false }
        let codeStr = String(content.dropFirst(7))
        guard let code = UInt32(codeStr) else { return false }
        return verify(code)
    }
}
