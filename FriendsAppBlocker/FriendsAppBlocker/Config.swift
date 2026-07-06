import Foundation

enum Config {
    // TOTP shared secret (20 bytes, same as ESP32)
    // Must match the secret in esp32/src/config.h
    static let totpSecret: [UInt8] = [
        0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x21, 0x44, 0x65, 0x61, 0x64,
        0x62, 0x65, 0x65, 0x66, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36
    ]

    // TOTP time step (30 seconds, standard)
    static let totpTimeStep: UInt64 = 30

    // Allow 1 step tolerance for clock drift (±30 seconds)
    static let totpTolerance: Int = 1
}
