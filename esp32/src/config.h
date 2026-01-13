#ifndef CONFIG_H
#define CONFIG_H

#define WIFI_SSID "your_wifi_name"
#define WIFI_PASSWORD "your_wifi_password"

// TOTP shared secret (20 bytes, same on iOS app)
const uint8_t TOTP_SECRET[] = {
    0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x21, 0x44, 0x65, 0x61, 0x64,
    0x62, 0x65, 0x65, 0x66, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36
};
const size_t TOTP_SECRET_LEN = sizeof(TOTP_SECRET);

// TOTP time step
#define TOTP_TIME_STEP 30

// NTP server
#define NTP_SERVER "pool.ntp.org"
#define GMT_OFFSET_SEC 0  // UTC
#define DAYLIGHT_OFFSET_SEC 0

#endif
