# iOS ESP32 Blocker

https://github.com/benjamin-feldman/esp32-blocker/raw/main/demo.mov

A simple app blocker that bricks your iPhone to lock distracting apps. The only way to unlock them is by scanning a QR code displayed on an ESP32. 

No network connection is needed between the iPhone and the ESP32: they use a shared secret + timestamp (TOTP algorithm, [RFC 6238](https://datatracker.ietf.org/doc/html/rfc6238)) to generate and verify codes. The ESP32 only needs internet at boot to sync its clock via NTP.

Inspired by [Brick](https://getbrick.app).

## Requirements

- Apple Developer account (required to use the Screen Time API)
- [PlatformIO](https://platformio.org/)
- [Xcode](https://developer.apple.com/xcode/) + [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Compatible hardware

- Lilygo ESP32 T-Display S3

## Setup

### (Optional) Enable git hooks
```bash
git config core.hooksPath .githooks
```
This enables a pre-commit hook that prevents from committing hardcoded WiFi credentials.

### WiFi Credentials for the ESP32
Edit `esp32/src/config.h`:

```cpp
#define WIFI_SSID "your_wifi_name"
#define WIFI_PASSWORD "your_wifi_password"
```
WiFi is only used for NTP time sync on boot.

### (Optional) Change the TOTP Secret
The 20 bytes TOTP secret can be found `esp32/src/config.h` and `ios/ESPBlocker/Config.swift`.

## Building
### ESP32
```bash
cd esp32
~/.platformio/penv/bin/pio run -t upload
```
### iOS

```bash
cd ios
xcodegen generate
open ESPBlocker.xcodeproj
```
Set your Development Team in Xcode, then build to device.
