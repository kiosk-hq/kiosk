/*
 * skooti_lock.ino — ESP32-C3 BLE scooter lock firmware
 *
 * Target:   ESP32-C3 (e.g. Seeed XIAO ESP32-C3, AI-Thinker ESP-C3-32S, ...)
 * Library:  NimBLE-Arduino (https://github.com/h2zero/NimBLE-Arduino)
 *           Install via Arduino Library Manager: "NimBLE-Arduino" by h2zero
 * Board:    "ESP32C3 Dev Module" in Arduino IDE / arduino-cli
 *
 * =========================================================================
 * OVERVIEW
 * =========================================================================
 * This firmware implements a BLE GATT peripheral that exposes a single
 * GATT service ("SKOOTI") with two characteristics:
 *
 *   CHALLENGE (notify + read):
 *     On READ — generate 16 fresh random bytes via esp_random(), store as
 *     the pending one-shot nonce (hex-encoded, 32 lowercase chars), return
 *     as a 32-char ASCII string.  Each read starts a new session; the
 *     previous nonce is invalidated (BLE retry support).
 *
 *   UNLOCK (write-no-response or write):
 *     On WRITE of "<reservation_id>|<mac_hex>" (pipe-separated ASCII):
 *       - Parse reservation_id and mac_hex from the write value.
 *       - Call skooti_verify_unlock(K_LOCK, SCOOTER_CODE, pending_nonce_hex,
 *                                   reservation_id, mac_hex).
 *       - On 1 (valid):  drive LED_GPIO HIGH for UNLOCK_DURATION_MS, then
 *                        LOW; consume the nonce (replay protection).
 *       - On 0 (invalid): stay locked; keep the nonce unconsumed so the
 *                          App Clip can retry with the same nonce.
 *
 * =========================================================================
 * PROVISIONING MODEL
 * =========================================================================
 * Each physical lock is provisioned with its own K_lock (32 bytes) at
 * manufacture/deployment:
 *
 *   K_lock = HMAC-SHA256(master_key, scooter_code)
 *
 * The server (kiosk-demo-skooti) holds the SINGLE master_key
 * (env: SKOOTI_MASTER_KEY, default "dev-master-key-0001" in dev).
 * The master_key NEVER leaves the server.  Each lock receives only its
 * own K_lock — a 32-byte value burned in here as K_LOCK[].
 *
 * Compromising one lock's K_lock does NOT expose the master key or any
 * other lock's key (key diversification).
 *
 * =========================================================================
 * MESSAGE LAYOUT (CRITICAL — DO NOT CHANGE)
 * =========================================================================
 * The MAC the server issues and the MAC this firmware recomputes both
 * cover the EXACT byte string:
 *
 *   message = scooter_code (UTF-8)
 *             + "|"
 *             + nonce_hex  (32 lowercase hex chars = 16 raw bytes)
 *             + "|"
 *             + reservation_id (UTF-8)
 *
 * Example:  "SK-001|00112233445566778899aabbccddeeff|resv-1"
 *
 * This matches:
 *   Ruby server:    UnlockAuthority.mac   (kiosk-server/unlock_authority.rb)
 *   Ruby sim:       LockSim#unlock        (kiosk-demo-skooti/lib/lock_sim.rb)
 *   C shared:       skooti_verify_unlock  (firmware/verify.c)
 *   C host test:    host_test.c           (proven by `make test`)
 *
 * =========================================================================
 * CRYPTO CONTRACT (proven on host without the board)
 * =========================================================================
 * The host_test.c + Makefile in this directory compile and test
 * hmac_sha256.c + verify.c (the exact same files #included / compiled
 * here) against the known-answer vectors from the server.  Run:
 *
 *   cd firmware && make test
 *
 * to prove the crypto matches before flashing.  The .ino itself is NOT
 * compiled on the host (ESP32 toolchain required); only the crypto core is.
 *
 * =========================================================================
 * BLE SERVICE / CHARACTERISTIC UUIDs
 * =========================================================================
 * Service:        "SKOOTI"
 *   UUID:         4e2a1000-5b3c-4b1e-9f8c-6d7e8a9b0c1d
 *
 * Challenge char: 4e2a1001-5b3c-4b1e-9f8c-6d7e8a9b0c1d
 *   Properties:   READ + NOTIFY
 *   Format:       32 ASCII hex chars (one-shot nonce)
 *
 * Unlock char:    4e2a1002-5b3c-4b1e-9f8c-6d7e8a9b0c1d
 *   Properties:   WRITE (+ WRITE_NR)
 *   Format:       "<reservation_id>|<64-char-mac-hex>"  (ASCII, pipe-delimited)
 *
 * =========================================================================
 * GPIO / LED WIRING
 * =========================================================================
 * LED_GPIO (GPIO 8 by default on ESP32-C3 DevKit onboard LED) is driven
 * HIGH for UNLOCK_DURATION_MS (3 seconds) on a valid unlock, then LOW.
 * Replace with a relay driver for a real lock actuator.
 *
 * ESP32-C3 DevKit onboard LED is active-LOW on some boards (GPIO 8 on
 * XIAO variant).  Adjust LED_ACTIVE_HIGH to match your board.
 * =========================================================================
 */

#include <Arduino.h>
#include <NimBLEDevice.h>
#include "hmac_sha256.h"
#include "verify.h"

/* --------------------------------------------------------------------------
 * Lock-specific provisioning constants
 * Bake these per physical lock at deploy time.
 * -------------------------------------------------------------------------- */

#define SCOOTER_CODE "SK-001"

/* K_LOCK = HMAC-SHA256("dev-master-key-0001", "SK-001")
 * = d147ea9da6b6957f83e46a58cb3e7aa56e4025497143b0897f68aa05e2fd842a
 * Replace with the real provisioned key in production.                     */
static const uint8_t K_LOCK[32] = {
    0xd1, 0x47, 0xea, 0x9d, 0xa6, 0xb6, 0x95, 0x7f,
    0x83, 0xe4, 0x6a, 0x58, 0xcb, 0x3e, 0x7a, 0xa5,
    0x6e, 0x40, 0x25, 0x49, 0x71, 0x43, 0xb0, 0x89,
    0x7f, 0x68, 0xaa, 0x05, 0xe2, 0xfd, 0x84, 0x2a
};

/* --------------------------------------------------------------------------
 * Hardware / timing config
 * -------------------------------------------------------------------------- */
#define LED_GPIO           8       /* GPIO driving the relay / LED         */
#define LED_ACTIVE_HIGH    1       /* 1 = HIGH means "on"; 0 = inverted    */
#define UNLOCK_DURATION_MS 3000    /* milliseconds the GPIO is driven high  */

/* --------------------------------------------------------------------------
 * BLE UUIDs (custom 128-bit)
 * -------------------------------------------------------------------------- */
#define SERVICE_UUID    "4e2a1000-5b3c-4b1e-9f8c-6d7e8a9b0c1d"
#define CHALLENGE_UUID  "4e2a1001-5b3c-4b1e-9f8c-6d7e8a9b0c1d"
#define UNLOCK_UUID     "4e2a1002-5b3c-4b1e-9f8c-6d7e8a9b0c1d"

/* --------------------------------------------------------------------------
 * State
 * -------------------------------------------------------------------------- */

/* Pending one-shot nonce: 32 lowercase hex chars + NUL */
static char   s_pending_nonce[33] = {0};
static bool   s_nonce_consumed    = true;  /* no nonce yet at boot */

/* Forward declarations */
static void   generate_nonce(void);
static void   do_unlock(void);

/* --------------------------------------------------------------------------
 * GATT Callbacks
 * -------------------------------------------------------------------------- */

class ChallengeCallbacks : public NimBLECharacteristicCallbacks {
public:
    /* On every BLE READ: generate a fresh nonce, store it, return it */
    void onRead(NimBLECharacteristic *pChar) override {
        generate_nonce();
        pChar->setValue(s_pending_nonce);   /* 32-char ASCII hex string */
        Serial.printf("[BLE] challenge nonce issued: %s\n", s_pending_nonce);
    }
};

class UnlockCallbacks : public NimBLECharacteristicCallbacks {
public:
    /*
     * On write: parse "<reservation_id>|<mac_hex>", verify, unlock or reject.
     *
     * The write value is:  reservation_id + "|" + mac_hex  (ASCII, UTF-8).
     * mac_hex must be exactly 64 lowercase hex characters.
     */
    void onWrite(NimBLECharacteristic *pChar) override {
        std::string val = pChar->getValue();
        Serial.printf("[BLE] unlock write received (%d bytes)\n", (int)val.size());

        /* Find the pipe delimiter */
        size_t pipe = val.find('|');
        if (pipe == std::string::npos) {
            Serial.println("[BLE] reject: no pipe delimiter");
            return;
        }

        std::string reservation_id = val.substr(0, pipe);
        std::string mac_hex        = val.substr(pipe + 1);

        Serial.printf("[BLE] reservation_id: %s\n", reservation_id.c_str());
        Serial.printf("[BLE] mac_hex:        %s\n", mac_hex.c_str());

        /* Replay guard: reject if nonce already consumed or not issued */
        if (s_nonce_consumed || s_pending_nonce[0] == '\0') {
            Serial.println("[BLE] reject: no valid pending nonce (replay guard)");
            return;
        }

        int ok = skooti_verify_unlock(
            K_LOCK,
            SCOOTER_CODE,
            s_pending_nonce,
            reservation_id.c_str(),
            mac_hex.c_str()
        );

        if (ok) {
            Serial.println("[BLE] UNLOCK — MAC verified; driving GPIO");
            s_nonce_consumed = true;   /* consume nonce — one-shot */
            do_unlock();
        } else {
            Serial.println("[BLE] REJECT — MAC invalid; staying locked");
            /* Nonce NOT consumed; App Clip may retry with same nonce */
        }
    }
};

/* --------------------------------------------------------------------------
 * GPIO helpers
 * -------------------------------------------------------------------------- */

static void gpio_unlock(void)
{
    digitalWrite(LED_GPIO, LED_ACTIVE_HIGH ? HIGH : LOW);
}

static void gpio_lock(void)
{
    digitalWrite(LED_GPIO, LED_ACTIVE_HIGH ? LOW : HIGH);
}

static void do_unlock(void)
{
    gpio_unlock();
    delay(UNLOCK_DURATION_MS);
    gpio_lock();
    Serial.println("[HW] locked again after " STR(UNLOCK_DURATION_MS) " ms");
}

#define _STR(x) #x
#define STR(x)  _STR(x)

/* --------------------------------------------------------------------------
 * Nonce generation
 * -------------------------------------------------------------------------- */

/*
 * generate_nonce — produce 16 random bytes via esp_random(), encode as
 * 32 lowercase hex chars, store in s_pending_nonce, mark unconsumed.
 *
 * esp_random() uses the ESP32 hardware RNG (RF-assisted noise source).
 */
static void generate_nonce(void)
{
    uint8_t raw[16];
    char    hex_chars[] = "0123456789abcdef";
    int     i;

    /* esp_random() returns a 32-bit word; call 4 times for 16 bytes */
    for (int w = 0; w < 4; w++) {
        uint32_t rnd = esp_random();
        raw[4*w+0] = (uint8_t)(rnd >> 24);
        raw[4*w+1] = (uint8_t)(rnd >> 16);
        raw[4*w+2] = (uint8_t)(rnd >>  8);
        raw[4*w+3] = (uint8_t)(rnd);
    }

    for (i = 0; i < 16; i++) {
        s_pending_nonce[2*i]   = hex_chars[(raw[i] >> 4) & 0x0F];
        s_pending_nonce[2*i+1] = hex_chars[ raw[i]        & 0x0F];
    }
    s_pending_nonce[32] = '\0';
    s_nonce_consumed    = false;
}

/* --------------------------------------------------------------------------
 * setup() — Arduino entry point
 * -------------------------------------------------------------------------- */

NimBLEServer           *pServer       = nullptr;
NimBLECharacteristic   *pChallenge    = nullptr;
NimBLECharacteristic   *pUnlock       = nullptr;

void setup(void)
{
    Serial.begin(115200);
    while (!Serial) delay(10);
    Serial.println("[boot] skooti_lock starting — " SCOOTER_CODE);

    /* GPIO */
    pinMode(LED_GPIO, OUTPUT);
    gpio_lock();   /* ensure locked at boot */

    /* BLE init */
    NimBLEDevice::init("skooti-" SCOOTER_CODE);
    NimBLEDevice::setMTU(185);   /* accommodate 64-char MAC + overhead */

    pServer = NimBLEDevice::createServer();
    /* No server callbacks needed for this minimal firmware */

    NimBLEService *pService = pServer->createService(SERVICE_UUID);

    /* Challenge characteristic: READ + NOTIFY */
    pChallenge = pService->createCharacteristic(
        CHALLENGE_UUID,
        NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
    );
    pChallenge->setCallbacks(new ChallengeCallbacks());

    /* Unlock characteristic: WRITE + WRITE_NR */
    pUnlock = pService->createCharacteristic(
        UNLOCK_UUID,
        NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
    );
    pUnlock->setCallbacks(new UnlockCallbacks());

    pService->start();

    NimBLEAdvertising *pAdv = NimBLEDevice::getAdvertising();
    pAdv->addServiceUUID(SERVICE_UUID);
    pAdv->setScanResponse(true);
    pAdv->start();

    Serial.println("[BLE] advertising as skooti-" SCOOTER_CODE);
    Serial.println("[BLE] service:   " SERVICE_UUID);
    Serial.println("[BLE] challenge: " CHALLENGE_UUID);
    Serial.println("[BLE] unlock:    " UNLOCK_UUID);
}

/* --------------------------------------------------------------------------
 * loop() — NimBLE is event-driven; nothing needed here
 * -------------------------------------------------------------------------- */

void loop(void)
{
    delay(1000);
}
