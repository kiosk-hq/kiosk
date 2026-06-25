/*
 * skooti_lock.ino — ESP32-C3 BLE scooter lock firmware (Arch 2: Ed25519)
 *
 * Target:   ESP32-C3 (e.g. Seeed XIAO ESP32-C3, AI-Thinker ESP-C3-32S, ...)
 * Library:  NimBLE-Arduino (https://github.com/h2zero/NimBLE-Arduino)
 *           Install via Arduino Library Manager: "NimBLE-Arduino" by h2zero
 * Board:    "ESP32C3 Dev Module" in Arduino IDE / arduino-cli
 *
 * =========================================================================
 * OVERVIEW — Arch 2 (offline Ed25519 rental-token verify)
 * =========================================================================
 * This firmware implements a BLE GATT peripheral that exposes a single
 * GATT service ("SKOOTI") with ONE characteristic:
 *
 *   UNLOCK (write):
 *     On WRITE of the wire rental token
 *       "<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>.<base64url(sig)>"
 *     the lock:
 *       1. Calls skooti_verify_token(SKOOTI_PUBKEY, token, SCOOTER_CODE, now)
 *          which checks: Ed25519 sig valid, scooter_code matches, exp > now.
 *       2. Checks the jti has not been consumed before (one-shot anti-replay,
 *          small in-RAM set — see JTI_CACHE_SIZE).
 *       3. On all-pass: adds jti to the consumed set, drives LED_GPIO HIGH for
 *          UNLOCK_DURATION_MS (3 s), then LOW (= unlocked).
 *       4. On any failure: stays locked, logs reason to Serial.
 *
 * There is NO challenge/response round-trip in Arch 2.  The server issues a
 * signed token (via start_rental) that the lock verifies fully offline.
 *
 * =========================================================================
 * PROVISIONING MODEL (Arch 2)
 * =========================================================================
 * Every lock is provisioned with:
 *   - SKOOTI_PUBKEY (32 bytes) — the skooti Ed25519 public key.
 *     One key for all locks; no per-lock secret.
 *     Baked as a constant below.
 *   - SCOOTER_CODE — this lock's own scooter identifier.
 *
 * Compromising one lock's firmware does NOT expose a signing capability or
 * any other lock's identity — the lock only holds a PUBLIC key.
 *
 * =========================================================================
 * TOKEN WIRE FORMAT (CRITICAL — DO NOT CHANGE)
 * =========================================================================
 * wire token = "<message>.<base64url(sig)>"  — split on the LAST '.'
 * message    = "<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>"
 * sig        = Ed25519 signature (64 bytes) over the message UTF-8 bytes
 *              → base64url-encoded, no padding
 *
 * Example (test vector from Plan 4.2 T1):
 *   message = "SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899"
 *   token   = "<message>.b-8ZCqcN1FZAXn4YbXPJXasTED2rwq0DSOXrcRSjI9ajReEBb9Y3m3YSHgNJEElCHSwnEGGYbNGiEWRCZD_yBw"
 *
 * This matches:
 *   Ruby server:  RentalTokenIssuer.issue  (kiosk-server)
 *   Ruby sim:     LockSim#unlock           (kiosk-demo-skooti/lib/lock_sim.rb)
 *   C shared:     skooti_verify_token      (firmware/verify.c)
 *   C host test:  host_test.c              (proven by `make test`)
 *
 * =========================================================================
 * CLOCK REQUIREMENT
 * =========================================================================
 * The lock checks exp > now.
 *
 * DEMO / BENCH:  now is taken from DEMO_NOW below (compile-time constant).
 *                This lets you test on the bench without RTC hardware.
 *                Set DEMO_NOW to a value less than the token's exp field.
 *                The test vector uses exp=1750000900 — set DEMO_NOW < that.
 *
 * PRODUCTION:    Replace the DEMO_NOW line in get_now() with one of:
 *   - DS3231 RTC:   now = rtc.getEpoch();
 *   - ESP32 SNTP:   configTime(0, 0, "pool.ntp.org"); time(nullptr);
 *   The scooter syncs time once online (WiFi or cellular) and uses it offline.
 *
 * =========================================================================
 * ANTI-REPLAY (jti one-shot)
 * =========================================================================
 * The lock keeps a small circular cache of recently used jtis in RAM
 * (JTI_CACHE_SIZE = 16 entries, 32 chars each + NUL).  Each jti is consumed
 * on first use; a repeat is rejected even within the exp window.
 *
 * For production persistence across reboots, store consumed jtis in NVS
 * (ESP32 non-volatile storage) — see the TODO comment in check_and_consume_jti.
 *
 * =========================================================================
 * CRYPTO CONTRACT (proven on host without the board)
 * =========================================================================
 *   cd firmware && make test
 * compiles ed25519/ + verify.c + host_test.c (NO .ino) and asserts all
 * vectors pass.  The .ino itself is NOT compiled on the host (needs the
 * ESP32 Arduino toolchain).
 *
 * =========================================================================
 * BLE SERVICE / CHARACTERISTIC UUIDs
 * =========================================================================
 * Service:      "SKOOTI"
 *   UUID:       4e2a1000-5b3c-4b1e-9f8c-6d7e8a9b0c1d
 *
 * Unlock char:  4e2a1002-5b3c-4b1e-9f8c-6d7e8a9b0c1d
 *   Properties: WRITE (+ WRITE_NR)
 *   Format:     wire rental token (ASCII, up to ~220 bytes; MTU negotiated to 256)
 *
 * =========================================================================
 * GPIO / LED WIRING
 * =========================================================================
 * LED_GPIO (GPIO 8 by default on ESP32-C3 DevKit onboard LED) is driven
 * HIGH for UNLOCK_DURATION_MS (3 seconds) on a valid unlock, then LOW.
 * Replace with a relay driver for a real lock actuator.
 *
 * ESP32-C3 DevKit onboard LED is active-LOW on some boards (GPIO 8 on the
 * XIAO variant).  Adjust LED_ACTIVE_HIGH to match your board.
 * =========================================================================
 */

#include <Arduino.h>
#include <NimBLEDevice.h>
#include "verify.h"

/* --------------------------------------------------------------------------
 * Lock-specific provisioning constants
 * Bake these per physical lock at deploy time.
 * -------------------------------------------------------------------------- */

#define SCOOTER_CODE "SK-001"

/*
 * SKOOTI_PUBKEY — skooti Ed25519 public key (32 raw bytes).
 * = 8857880d21f87b85872f31aeea8d0024acebb2fdf933b25a479f4f9e80babefd
 * One key for all locks.  The lock only holds the PUBLIC key.
 * The private signing key stays on the server (never in firmware).
 */
static const uint8_t SKOOTI_PUBKEY[32] = {
    0x88, 0x57, 0x88, 0x0d, 0x21, 0xf8, 0x7b, 0x85,
    0x87, 0x2f, 0x31, 0xae, 0xea, 0x8d, 0x00, 0x24,
    0xac, 0xeb, 0xb2, 0xfd, 0xf9, 0x33, 0xb2, 0x5a,
    0x47, 0x9f, 0x4f, 0x9e, 0x80, 0xba, 0xbe, 0xfd
};

/* --------------------------------------------------------------------------
 * DEMO_NOW — injected clock for bench / demo use (REPLACE in production).
 *
 * Set this to a value strictly less than the exp field of the token you are
 * testing.  The test vector has exp=1750000900; use DEMO_NOW=1750000800.
 *
 * In production replace the body of get_now() below with RTC / SNTP.
 * -------------------------------------------------------------------------- */
#define DEMO_NOW ((uint64_t)1750000800ULL)

/* --------------------------------------------------------------------------
 * Hardware / timing config
 * -------------------------------------------------------------------------- */
#define LED_GPIO           8       /* GPIO driving the relay / LED         */
#define LED_ACTIVE_HIGH    1       /* 1 = HIGH means "on"; 0 = inverted    */
#define UNLOCK_DURATION_MS 3000    /* milliseconds the GPIO is driven high  */

/* --------------------------------------------------------------------------
 * BLE UUIDs (custom 128-bit)
 * -------------------------------------------------------------------------- */
#define SERVICE_UUID "4e2a1000-5b3c-4b1e-9f8c-6d7e8a9b0c1d"
#define UNLOCK_UUID  "4e2a1002-5b3c-4b1e-9f8c-6d7e8a9b0c1d"

/* --------------------------------------------------------------------------
 * JTI one-shot anti-replay cache
 *
 * A fixed-size circular buffer of recently consumed jtis.
 * jti = 32 hex chars + NUL = 33 bytes.
 *
 * TODO (production): persist consumed jtis in NVS so reboots don't reopen
 * the anti-replay window.  Use esp_partition API or Preferences library.
 * -------------------------------------------------------------------------- */
#define JTI_CACHE_SIZE 16
#define JTI_LEN        33   /* 32 hex chars + NUL */

static char  s_jti_cache[JTI_CACHE_SIZE][JTI_LEN];
static int   s_jti_head = 0;   /* next slot to overwrite (circular) */
static int   s_jti_count = 0;  /* total entries populated (cap JTI_CACHE_SIZE) */

/*
 * jti_seen — return true if jti is in the consumed cache.
 */
static bool jti_seen(const char *jti)
{
    for (int i = 0; i < s_jti_count; i++) {
        if (strncmp(s_jti_cache[i], jti, JTI_LEN - 1) == 0) return true;
    }
    return false;
}

/*
 * jti_consume — add jti to the cache (circular overwrite on full).
 */
static void jti_consume(const char *jti)
{
    strncpy(s_jti_cache[s_jti_head], jti, JTI_LEN - 1);
    s_jti_cache[s_jti_head][JTI_LEN - 1] = '\0';
    s_jti_head = (s_jti_head + 1) % JTI_CACHE_SIZE;
    if (s_jti_count < JTI_CACHE_SIZE) s_jti_count++;
}

/* --------------------------------------------------------------------------
 * Clock source
 *
 * DEMO: returns DEMO_NOW (compile-time constant).
 * PRODUCTION: replace with DS3231 rtc.getEpoch() or time(nullptr) after SNTP.
 * -------------------------------------------------------------------------- */
static uint64_t get_now(void)
{
    /* PRODUCTION: return (uint64_t)time(nullptr); */
    return DEMO_NOW;
}

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

#define _STR(x) #x
#define STR(x)  _STR(x)

static void do_unlock(void)
{
    gpio_unlock();
    delay(UNLOCK_DURATION_MS);
    gpio_lock();
    Serial.println("[HW] locked again after " STR(UNLOCK_DURATION_MS) " ms");
}

/* --------------------------------------------------------------------------
 * BLE GATT Callback
 * -------------------------------------------------------------------------- */

class UnlockCallbacks : public NimBLECharacteristicCallbacks {
public:
    /*
     * On write: receive the wire rental token, verify it, unlock or reject.
     *
     * Wire token format:
     *   "<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>.<base64url(sig)>"
     *
     * A typical token is ~180-220 bytes.  MTU is negotiated to 256 in setup().
     */
    void onWrite(NimBLECharacteristic *pChar) override
    {
        std::string val = pChar->getValue();
        Serial.printf("[BLE] unlock write received (%d bytes)\n", (int)val.size());

        if (val.empty()) {
            Serial.println("[BLE] reject: empty write");
            return;
        }

        const char *token = val.c_str();
        uint64_t    now   = get_now();

        /* 1. Signature + scooter_code + expiry check */
        int ok = skooti_verify_token(SKOOTI_PUBKEY, token, SCOOTER_CODE, now);
        if (!ok) {
            Serial.println("[BLE] REJECT — token invalid (sig/code/exp)");
            return;
        }

        /* 2. Extract jti for one-shot check */
        char jti[JTI_LEN];
        if (!skooti_parse_jti(token, jti, sizeof(jti))) {
            Serial.println("[BLE] REJECT — could not parse jti");
            return;
        }

        /* 3. One-shot anti-replay */
        if (jti_seen(jti)) {
            Serial.printf("[BLE] REJECT — jti already consumed: %s\n", jti);
            return;
        }

        /* All checks passed — consume jti and unlock */
        jti_consume(jti);
        Serial.printf("[BLE] UNLOCK — token verified; jti=%s; driving GPIO\n", jti);
        do_unlock();
    }
};

/* --------------------------------------------------------------------------
 * setup() — Arduino entry point
 * -------------------------------------------------------------------------- */

NimBLECharacteristic *pUnlock = nullptr;

void setup(void)
{
    Serial.begin(115200);
    while (!Serial) delay(10);
    Serial.println("[boot] skooti_lock Arch2 — " SCOOTER_CODE);

    /* GPIO */
    pinMode(LED_GPIO, OUTPUT);
    gpio_lock();   /* ensure locked at boot */

    /* BLE init — negotiate MTU 256 to accommodate ~220-byte tokens */
    NimBLEDevice::init("skooti-" SCOOTER_CODE);
    NimBLEDevice::setMTU(256);

    NimBLEServer *pServer = NimBLEDevice::createServer();

    NimBLEService *pService = pServer->createService(SERVICE_UUID);

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
    Serial.println("[BLE] service: " SERVICE_UUID);
    Serial.println("[BLE] unlock:  " UNLOCK_UUID);
    Serial.printf( "[BLE] demo now: %llu (replace get_now() for production)\n",
                   (unsigned long long)get_now());
}

/* --------------------------------------------------------------------------
 * loop() — NimBLE is event-driven; nothing needed here
 * -------------------------------------------------------------------------- */
void loop(void)
{
    delay(1000);
}
