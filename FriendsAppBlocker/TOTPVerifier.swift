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

    /// Generate TOTP code for a given time step using SHA1(secret || counter)
    func generateCode(for counter: UInt64) -> UInt32 {
        // Create input: secret + counter bytes (big-endian)
        var input = secret
        var counterBE = counter.bigEndian
        withUnsafeBytes(of: &counterBE) { input.append(contentsOf: $0) }

        // Compute SHA1
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        _ = input.withUnsafeBytes { inputPtr in
            CC_SHA1(inputPtr.baseAddress, CC_LONG(input.count), &hash)
        }

        // Dynamic truncation
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
