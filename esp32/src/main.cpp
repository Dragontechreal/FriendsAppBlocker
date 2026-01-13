#include <Arduino.h>
#include <WiFi.h>
#include <time.h>
#include <TFT_eSPI.h>
#include <qrcode.h>
#include <mbedtls/md.h>
#include "config.h"

TFT_eSPI tft = TFT_eSPI();

// QR code buffer
// Version 3 QR = 29x29 modules, buffer size = ((29*29)+7)/8 = 106 bytes
#define QR_VERSION 3
#define QR_BUFFER_SIZE 106
QRCode qrcode;
uint8_t qrcodeData[QR_BUFFER_SIZE];

// Last displayed code (to avoid unnecessary redraws)
uint32_t lastCode = 0;
uint32_t lastTimeStep = 0;

// Generate TOTP code using HMAC-SHA1
uint32_t generateTOTP(uint64_t timeStep) {
    // Convert time step to big-endian bytes
    uint8_t timeBytes[8];
    for (int i = 7; i >= 0; i--) {
        timeBytes[i] = timeStep & 0xFF;
        timeStep >>= 8;
    }

    // Compute HMAC-SHA1
    uint8_t hash[20];
    mbedtls_md_context_t ctx;
    mbedtls_md_init(&ctx);
    mbedtls_md_setup(&ctx, mbedtls_md_info_from_type(MBEDTLS_MD_SHA1), 1);
    mbedtls_md_hmac_starts(&ctx, TOTP_SECRET, TOTP_SECRET_LEN);
    mbedtls_md_hmac_update(&ctx, timeBytes, 8);
    mbedtls_md_hmac_finish(&ctx, hash);
    mbedtls_md_free(&ctx);

    // Dynamic truncation (RFC 6238)
    int offset = hash[19] & 0x0F;
    uint32_t code = ((hash[offset] & 0x7F) << 24) |
                    ((hash[offset + 1] & 0xFF) << 16) |
                    ((hash[offset + 2] & 0xFF) << 8) |
                    (hash[offset + 3] & 0xFF);

    // 6-digit code
    return code % 1000000;
}

void displayQRCode(uint32_t code) {
    // Create QR content: "UNLOCK:123456"
    char content[32];
    snprintf(content, sizeof(content), "UNLOCK:%06lu", code);

    // Generate QR code (version 3, ECC_LOW for smaller size)
    qrcode_initText(&qrcode, qrcodeData, QR_VERSION, ECC_LOW, content);

    // Calculate QR code display size - maximize for 170x320 display
    int qrSize = qrcode.size;
    int scale = 160 / qrSize; // Fit in ~160px width
    int qrPixelSize = qrSize * scale;
    int offsetX = (170 - qrPixelSize) / 2;
    int offsetY = (320 - qrPixelSize) / 2; // Center vertically

    // Black background
    tft.fillScreen(TFT_BLACK);

    // Draw white QR modules
    for (int y = 0; y < qrSize; y++) {
        for (int x = 0; x < qrSize; x++) {
            if (qrcode_getModule(&qrcode, x, y)) {
                tft.fillRect(offsetX + x * scale, offsetY + y * scale, scale, scale, TFT_WHITE);
            }
        }
    }
}

void initDisplay() {
    tft.fillScreen(TFT_BLACK);
    tft.setTextColor(TFT_WHITE, TFT_BLACK);
    tft.setTextDatum(TL_DATUM);
    tft.setTextSize(2);
}

void connectWiFi() {
    // Show "WiFi"
    tft.drawString("WiFi", 20, 120);
    int dotX = 68;

    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

    int attempts = 0;
    int dots = 0;
    while (WiFi.status() != WL_CONNECTED && attempts < 30) {
        // Animate dots
        dots = (dots % 3) + 1;
        tft.fillRect(dotX, 120, 50, 20, TFT_BLACK); // Clear dots area
        for (int i = 0; i < dots; i++) {
            tft.drawString(".", dotX + (i * 8), 120);
        }
        delay(400);
        Serial.print(".");
        attempts++;
    }

    // Clear dots
    tft.fillRect(dotX, 120, 50, 20, TFT_BLACK);

    if (WiFi.status() == WL_CONNECTED) {
        Serial.println("\nWiFi connected");
        tft.setTextColor(TFT_GREEN, TFT_BLACK);
        tft.drawString("OK", dotX, 120);
        tft.setTextColor(TFT_WHITE, TFT_BLACK);
    } else {
        Serial.println("\nWiFi failed!");
        tft.setTextColor(TFT_RED, TFT_BLACK);
        tft.drawString("FAIL", dotX, 120);
        while (1) delay(1000); // Halt
    }
}

void syncTime() {
    // Show "Sync"
    tft.drawString("Sync", 20, 150);
    int dotX = 68;

    configTime(GMT_OFFSET_SEC, DAYLIGHT_OFFSET_SEC, NTP_SERVER);

    struct tm timeinfo;
    int attempts = 0;
    int dots = 0;
    while (!getLocalTime(&timeinfo) && attempts < 20) {
        // Animate dots
        dots = (dots % 3) + 1;
        tft.fillRect(dotX, 150, 50, 20, TFT_BLACK); // Clear dots area
        for (int i = 0; i < dots; i++) {
            tft.drawString(".", dotX + (i * 8), 150);
        }
        Serial.println("Waiting for NTP...");
        delay(200);
        attempts++;
    }

    // Clear dots
    tft.fillRect(dotX, 150, 50, 20, TFT_BLACK);

    if (attempts >= 20) {
        tft.setTextColor(TFT_RED, TFT_BLACK);
        tft.drawString("FAIL", dotX, 150);
        while (1) delay(1000); // Halt
    }

    Serial.println("Time synced!");
    Serial.println(&timeinfo, "%Y-%m-%d %H:%M:%S");

    tft.setTextColor(TFT_GREEN, TFT_BLACK);
    tft.drawString("OK", dotX, 150);

    delay(500); // Brief pause to see the status
}

void setup() {
    Serial.begin(115200);
    Serial.println("ESP32 Blocker starting...");

    // Power on the LCD (T-Display S3 requires this)
    pinMode(15, OUTPUT);
    digitalWrite(15, HIGH);
    delay(100);

    // Initialize display
    tft.init();
    tft.setRotation(0); // Portrait mode
    tft.invertDisplay(true); // Fix inverted colors on T-Display S3

    // Turn on backlight
    pinMode(TFT_BL, OUTPUT);
    digitalWrite(TFT_BL, HIGH);

    initDisplay();

    connectWiFi();
    syncTime();
}

void loop() {
    time_t now;
    time(&now);
    uint64_t timeStep = now / TOTP_TIME_STEP;

    // Only update if time step changed
    if (timeStep != lastTimeStep) {
        uint32_t code = generateTOTP(timeStep);
        displayQRCode(code);
        lastTimeStep = timeStep;
        lastCode = code;

        Serial.printf("TOTP: %06lu (step %llu)\n", code, timeStep);
    }

    delay(1000);
}
