# skooti firmware — ESP32-C3 BLE scooter lock

This directory contains:

| File | Purpose |
|------|---------|
| `skooti_lock.ino` | Arduino-ESP32 firmware (ESP32-C3 + NimBLE-Arduino) |
| `hmac_sha256.h/c` | Portable SHA-256 + HMAC-SHA256 (C99, no platform deps) |
| `verify.h/c` | `skooti_verify_unlock()` — shared crypto, links into both the firmware and the host test |
| `host_test.c` | Host-side crypto proof (runs on Mac/Linux without the board) |
| `Makefile` | `make test` = C tests + Ruby crosscheck |

The crypto is **proven on the host** before flashing.  The BLE flow is
validated when Phil's ESP32-C3 board arrives.

---

## Crypto contract (host-provable now)

```
master_key  = "dev-master-key-0001"          # server-only; never in firmware
K_lock      = HMAC-SHA256(master_key, scooter_code)   # provisioned into lock
mac         = HMAC-SHA256(K_lock, "scooter_code|nonce_hex|reservation_id")
```

Run:

```sh
cd firmware
make test
```

Expected output (all 8 assertions pass, crosscheck matches `896eec16...`):

```
=== skooti firmware crypto host test ===
...
=== Results: 8 passed, 0 failed ===
ALL PASS
--- Ruby <-> C crosscheck ---
  Ruby  mac : 896eec16ca0d164293762269f0d34c319a41b4a463bedc2ce11f3269a49e9b1f
  C     mac : 896eec16ca0d164293762269f0d34c319a41b4a463bedc2ce11f3269a49e9b1f
  MATCH — C HMAC == Ruby/OpenSSL (server) HMAC
```

This proves the firmware's HMAC-SHA256 matches the Kiosk server (Ruby/OpenSSL)
byte-for-byte.  The `.ino` is NOT compiled on the host (ESP32 toolchain
required); only `hmac_sha256.c` + `verify.c` are tested here.

---

## BLE service / characteristics

| | UUID | Properties | Format |
|--|------|-----------|--------|
| **Service** | `4e2a1000-5b3c-4b1e-9f8c-6d7e8a9b0c1d` | — | — |
| **Challenge** | `4e2a1001-5b3c-4b1e-9f8c-6d7e8a9b0c1d` | READ + NOTIFY | 32 ASCII hex chars (one-shot nonce) |
| **Unlock** | `4e2a1002-5b3c-4b1e-9f8c-6d7e8a9b0c1d` | WRITE + WRITE_NR | `<reservation_id>|<64-char-mac-hex>` |

### Unlock flow (App Clip → lock)

1. App Clip connects to `skooti-SK-001` BLE peripheral.
2. App Clip **reads** the Challenge characteristic → receives 32 hex chars (nonce).
3. App Clip sends nonce + reservation_id to the Kiosk server (`/kiosk/exec {name:"unlock", ...}`).
4. Server verifies KYC + paid reservation → returns `mac` (64 hex chars).
5. App Clip **writes** `"<reservation_id>|<mac_hex>"` to the Unlock characteristic.
6. Lock recomputes `HMAC-SHA256(K_lock, "SK-001|nonce_hex|reservation_id")`, constant-time
   compares, drives GPIO HIGH for 3 s = unlocked; nonce consumed (replay-safe).

---

## GPIO / LED wiring

```
ESP32-C3 GPIO 8  →  relay driver (or onboard LED for demo)
                     HIGH = unlocked (3 s), then LOW = locked
```

Edit `LED_GPIO` and `LED_ACTIVE_HIGH` in `skooti_lock.ino` to match your board.
On XIAO ESP32-C3 the onboard LED is active-LOW on GPIO 8 → set `LED_ACTIVE_HIGH 0`.

---

## Provisioning

**Every physical lock is provisioned with its own `K_lock` (32 bytes):**

```ruby
# server-side, one-time per lock
K_lock = OpenSSL::HMAC.digest("SHA256", master_key, scooter_code)
```

The `master_key` **never leaves the server**.  Each lock receives only its own
`K_lock`, burned into `K_LOCK[]` in `skooti_lock.ino`.

Compromising one lock's `K_lock` does not expose the master key or any other
lock's key (diversified-key scheme).

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
5. Open `skooti_lock.ino`, verify `K_LOCK[]` matches your lock's provisioned key.
6. Upload.  Open Serial Monitor at 115200 baud to see nonce + unlock events.

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
| `HMAC-SHA256(K_lock, "scooter_code|nonce_hex|reservation_id")` in C == Ruby/OpenSSL | **PROVEN** (`make test`) |
| K_lock derivation `HMAC-SHA256(master_key, scooter_code)` in C matches server | **PROVEN** (`make test` test 6) |
| One-shot nonce (replay) guard in software LockSim | **PROVEN** (Part B tests) |
| BLE GATT advertising + connect + read challenge | **Not yet** — needs board |
| GPIO drives relay on valid MAC | **Not yet** — needs board |
| App Clip ↔ lock BLE end-to-end | **Not yet** — needs board + Apple account |
