# skooti firmware — ESP32-C3 BLE scooter lock (Arch 2: Ed25519)

This directory contains:

| File | Purpose |
|------|---------|
| `skooti_lock.ino` | Arduino-ESP32 firmware (ESP32-C3 + NimBLE-Arduino) |
| `verify.h/c` | `skooti_verify_token()` — portable Ed25519 token verify; shared by firmware and host test |
| `host_test.c` | Host-side crypto proof (runs on Mac/Linux, no board required) |
| `crosscheck_main.c` | Ruby-signed token → C verify helper (invoked by `make crosscheck`) |
| `Makefile` | `make test` = C assertions + Ruby↔C crosscheck |
| `ed25519/` | Vendored orlp/ed25519 (zlib license, public-domain-style) — portable Ed25519 with detached verify |

The crypto is **proven on the host** before flashing.  The BLE flow is
validated when the ESP32-C3 board is available.

---

## Crypto contract (Arch 2 — offline Ed25519)

```
skooti_pubkey   = <32 bytes, baked into every lock>
message         = "scooter_code|reservation_id|iat|exp|jti"
sig             = Ed25519(private_signing_key, message)   # server-side only
wire token      = "<message>.<base64url(sig)>"

lock verifies:
  1. Ed25519-verify(sig, message, skooti_pubkey)
  2. scooter_code == SCOOTER_CODE
  3. exp > now
  4. jti not yet consumed (one-shot, caller checks)
```

Run:

```sh
cd firmware
make test
```

Expected output (10 assertions pass, crosscheck MATCH):

```
--- C host test ---
=== skooti firmware Ed25519 host test (Arch 2) ===
Public key : 8857880d21f87b85872f31aeea8d0024acebb2fdf933b25a479f4f9e80babefd
Scooter    : SK-001
...
=== Results: 10 passed, 0 failed ===
ALL PASS

--- Ruby <-> C crosscheck ---
  Ruby-signed token: SK-001|resv-live|...
  C verify result: 1
  MATCH — C verifier accepts Ruby/OpenSSL-signed token ✓
```

This proves the C Ed25519 verifier correctly verifies tokens signed by the Kiosk
Ruby server (same RFC 8032 Ed25519 semantics via OpenSSL).  The `.ino` is NOT
compiled on the host (ESP32 Arduino toolchain required); only `ed25519/` +
`verify.c` + test helpers are exercised here.

---

## BLE service / characteristics

| | UUID | Properties | Format |
|--|------|-----------|--------|
| **Service** | `4e2a1000-5b3c-4b1e-9f8c-6d7e8a9b0c1d` | — | — |
| **Unlock** | `4e2a1002-5b3c-4b1e-9f8c-6d7e8a9b0c1d` | WRITE + WRITE_NR | wire rental token (ASCII, ≤ 512 bytes; MTU negotiated to 256) |

### Unlock flow (App Clip → lock, Arch 2)

1. App Clip receives the rental token in the `rt=` URL parameter of its launch link.
2. App Clip connects to `skooti-SK-001` BLE peripheral.
3. App Clip **writes** the wire rental token to the Unlock characteristic.
4. Lock runs `skooti_verify_token(SKOOTI_PUBKEY, token, SCOOTER_CODE, now)`:
   checks Ed25519 sig, scooter_code match, exp > now.
5. Lock checks jti not yet consumed (in-RAM circular set; NVS in production).
6. On all-pass: consumes jti, drives GPIO HIGH for 3 s = unlocked.
7. On any failure: stays locked; logs reason to Serial.

**No server round-trip at unlock time.**  The token was issued by the server
at `start_rental` and verified offline by the lock.

---

## Clock requirement

The lock checks `exp > now`.

- **Demo / bench:** `DEMO_NOW` in `skooti_lock.ino` is a compile-time constant.
  Set it to a value less than the token's `exp` field (test vector: exp=1750000900,
  DEMO_NOW=1750000800).
- **Production:** replace the body of `get_now()` in `skooti_lock.ino` with one of:
  - DS3231 RTC: `return (uint64_t)rtc.getEpoch();`
  - ESP32 SNTP: `configTime(0, 0, "pool.ntp.org"); return (uint64_t)time(nullptr);`
  The scooter syncs time once online (WiFi or cellular) and uses it offline.

---

## GPIO / LED wiring

```
ESP32-C3 GPIO 8  →  relay driver (or onboard LED for demo)
                     HIGH = unlocked (3 s), then LOW = locked
```

Edit `LED_GPIO` and `LED_ACTIVE_HIGH` in `skooti_lock.ino` to match your board.
On XIAO ESP32-C3 the onboard LED is active-LOW on GPIO 8 → set `LED_ACTIVE_HIGH 0`.

---

## Provisioning (Arch 2)

Every physical lock is provisioned with:

- **`SKOOTI_PUBKEY`** (32 bytes) — the skooti Ed25519 public key, one key for all locks.
- **`SCOOTER_CODE`** — this lock's own identifier.

The private signing key **never leaves the server**.  Compromising a lock's
firmware exposes only the public key (already semi-public) — no signing capability,
no other lock compromised.

---

## Flashing — Arduino IDE

1. Install **Arduino IDE 2.x** (https://www.arduino.cc/en/software).
2. Add the ESP32 board package:
   - Preferences → Additional Boards Manager URLs → add:
     `https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json`
   - Boards Manager → install "esp32 by Espressif Systems" (≥ 3.x).
3. Install **NimBLE-Arduino**:
   - Library Manager → search "NimBLE-Arduino" by h2zero → Install.
4. Select board: **"ESP32C3 Dev Module"** (or your exact variant).
5. Open `skooti_lock.ino`, verify `SKOOTI_PUBKEY[]` and `SCOOTER_CODE`.
6. Adjust `DEMO_NOW` or replace `get_now()` for production clock.
7. Upload.  Open Serial Monitor at 115200 baud to see unlock events.

## Flashing — arduino-cli

```sh
# Install board and library
arduino-cli core update-index
arduino-cli core install esp32:esp32
arduino-cli lib install "NimBLE-Arduino"

# Compile (adjust board FQBN for your variant)
arduino-cli compile --fqbn esp32:esp32:esp32c3 firmware/

# Upload (replace /dev/ttyUSB0 with your port)
arduino-cli upload -p /dev/ttyUSB0 --fqbn esp32:esp32:esp32c3 firmware/
```

---

## What is and is not proven here

| Claim | Status |
|-------|--------|
| Ed25519-verify in C accepts the T1 known-answer token vector | **PROVEN** (`make test` test 1) |
| Expired token (now > exp) rejected | **PROVEN** (`make test` test 2) |
| Wrong scooter_code rejected | **PROVEN** (`make test` test 3) |
| Flipped sig byte rejected | **PROVEN** (`make test` test 4) |
| Malformed / truncated / NULL tokens → 0, no crash | **PROVEN** (`make test` test 5) |
| C verifier accepts a freshly Ruby/OpenSSL-signed token | **PROVEN** (`make crosscheck`) |
| jti one-shot anti-replay in software LockSim | **PROVEN** (T2 rake demo) |
| BLE GATT advertising + connect + write unlock | **Not yet** — needs board |
| GPIO drives relay on valid token | **Not yet** — needs board |
| App Clip → lock BLE end-to-end | **Not yet** — needs board + Apple account |
