# skooti firmware — ESP32-C3 BLE scooter lock (offline Ed25519)

This directory contains:

| File | Purpose |
|------|---------|
| `skooti_lock.ino` | Arduino-ESP32 firmware (ESP32-C3 + NimBLE-Arduino) |
| `verify.h/c` | `skooti_verify_token()` — portable Ed25519 token verify; shared by firmware and host test |
| `jti_store.h/c` | `jti_seen_or_insert()` — durable one-shot `jti` store; in-memory on the host, NVS-backed on the board |
| `host_test.c` | Host-side crypto proof (runs on Mac/Linux, no board required) |
| `crosscheck_main.c` | Ruby-signed token → C verify helper (invoked by `make crosscheck`) |
| `token_vectors.rb` | The rental-token conformance vectors — the grammar, and what the vectors do not cover, stated in its header |
| `crosscheck_grammar.rb` | Runs every vector through all three readers of the token — this C verifier, the shipped `RentalTokenIssuer.verify` and `script/lock_sim.rb` (invoked by `make crosscheck`) |
| `Makefile` | `make test` = C assertions + Ruby↔C crosscheck |
| `ed25519/` | Vendored orlp/ed25519 (zlib license, public-domain-style) — portable Ed25519 with detached verify |

The crypto is **proven on the host** before flashing.  The BLE flow is
validated when the ESP32-C3 board is available.

---

## Crypto contract (offline Ed25519 rental token)

```
skooti_pubkey   = <32 bytes, baked into every lock>
message         = "kiosk-rental-v1|scooter_code|reservation_id|iat|exp|jti"
                   ^^^^^^^^^^^^^^^^^
                   domain-separation tag (field 0) — lock rejects any token
                   whose field 0 is not exactly this string
sig             = Ed25519(private_signing_key, message)   # server-side only
wire token      = "<message>.<base64url(sig)>"

lock verifies:
  1. the wire token is at most 512 bytes (SKOOTI_TOKEN_MAX)
  2. Ed25519-verify(sig, message, skooti_pubkey)
  3. the message splits into EXACTLY 6 pipe fields, none of them empty —
     fewer or more is refused, so field[4] is always the expiry and never a
     shifted field, and a trailing '|' is a seventh field rather than punctuation
  4. field[0] == "kiosk-rental-v1"  (domain-separation tag, constant-time compare)
  5. scooter_code (field[1]) == SCOOTER_CODE
  6. iat (field[3]) and exp (field[4]) are 1-20 plain ASCII digits
  7. exp (field[4]) > now
  8. jti (field[5]) is 32 lowercase hex characters
  9. jti not yet consumed — jti_seen_or_insert(jti, exp, now) == 0
     (NVS-backed durable store; entries retained until exp; survives reboot)
```

The whole grammar — every field's charset, the delimiter rule and the wire cap
— is stated in `../RENTAL_TOKEN.md`, the canonical page for this token, and
`make crosscheck` holds all three readers to it.

Run:

```sh
cd firmware
make test
```

Expected output (35 assertions pass, crosscheck MATCH). The `...` lines are
elisions in this quotation, not in the run:

```
--- C host test ---
=== skooti firmware Ed25519 host test (offline Ed25519 rental token) ===
Public key : b39f3a0333c662d3937684f21c91f7722161f8b0b4f4a79b336b463eb8f570f4
Scooter    : SK-001
...
=== Results: 35 passed, 0 failed ===
ALL PASS

--- Ruby ↔ C crosscheck ---
  Ruby-signed token: kiosk-rental-v1|SK-001|resv-live|...
  C verify result: 1
  MATCH — C verifier accepts Ruby/OpenSSL-signed token ✓
  Rental-token grammar — 35 live-signed vectors through all 3 readers of this token:
    axis   vector                                     expect  C       issuer  lock
    count  six fields, well-formed                    accept  accept  accept  accept  MATCH ✓
    count  seven segments, one trailing delimiter     reject  reject  reject  reject  MATCH ✓
    ...
    int    exp with a leading plus                    reject  reject  reject  reject  MATCH ✓
    ...
    jti    jti in uppercase hex                       reject  reject  reject  reject  MATCH ✓
    ...
  MATCH — all 3 readers gave the declared answer on every one of these 35 vectors (axes: count, empty, tag, int, jti, length, fresh) ✓
```

This proves the C Ed25519 verifier correctly verifies tokens signed by the Kiosk
Ruby server (same RFC 8032 Ed25519 semantics via OpenSSL).  The `.ino` is NOT
compiled on the host (ESP32 Arduino toolchain required); what `make test` builds
is `ed25519/` + `verify.c` + `jti_store.c` + the test harness.

---

## BLE service / characteristics

| | UUID | Properties | Format |
|--|------|-----------|--------|
| **Service** | `4e2a1000-5b3c-4b1e-9f8c-6d7e8a9b0c1d` | — | — |
| **Unlock** | `4e2a1002-5b3c-4b1e-9f8c-6d7e8a9b0c1d` | WRITE + WRITE_NR | wire rental token (ASCII, ≤ 512 bytes; MTU negotiated to 256) |

### Unlock flow (App Clip → lock, offline)

1. App Clip receives the rental token in the `rt=` URL parameter of its launch link.
2. App Clip connects to `skooti-SK-001` BLE peripheral.
3. App Clip **writes** the wire rental token to the Unlock characteristic.
4. Lock runs `skooti_verify_token(SKOOTI_PUBKEY, token, SCOOTER_CODE, now)`:
   checks the wire cap, the Ed25519 sig, a six-field message with no empty
   field, domain tag (`kiosk-rental-v1`), scooter_code match, plain-digit iat
   and exp, exp > now, and a 32-lowercase-hex jti.
5. Lock calls `jti_seen_or_insert(jti, exp, now)` — rejects if jti already consumed
   (durable NVS-backed store; survives reboot; entries retained until their exp).
6. On all-pass: records jti, drives GPIO HIGH for 3 s = unlocked.
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

> **CRITICAL — Unsynced / dead clock must HARD-FAIL (required before deployment)**
>
> If `get_now()` returns 0 or a boot-epoch value (e.g. `time()` before any NTP sync),
> the check `exp > now_unix` passes for **every** token with any future `exp`, defeating
> the expiry field entirely — fail-OPEN.  A stolen token with a far-future `exp` would
> be accepted forever.
>
> In production, `get_now()` **must** return `UINT64_MAX` (or another guaranteed-past-
> any-valid-`exp` sentinel) when the clock is unsynced:
>
> ```c
> uint64_t t = (uint64_t)time(nullptr);
> if (t < 1700000000ULL) return UINT64_MAX;  /* unsynced → fail-CLOSED */
> return t;
> ```
>
> `UINT64_MAX > any valid exp` → `skooti_verify_token` returns 0 for all tokens until
> the clock is credible.  The demo's `DEMO_NOW` constant is safe; this is a
> productionisation note.

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

Every physical lock is provisioned with:

- **`SKOOTI_PUBKEY`** (32 bytes) — the skooti Ed25519 public key, one key for all locks.
- **`SCOOTER_CODE`** — this lock's own identifier.

The private signing key **never leaves the server**.  Compromising a lock's
firmware exposes only the public key (already semi-public) — no signing capability,
no other lock compromised.

The key baked into the sources here is the **dev** key
(`../config/dev_unlock_key.pem`), so `make test` and the demo drivers agree out of
the box.  A real deployment flashes the public half of the server's own
`KIOSK_UNLOCK_SIGNING_KEY_PEM` instead:

```sh
openssl pkey -in unlock_key.pem -pubout -outform DER | tail -c 32 | xxd -p -c 32
```

That property — "the private key never leaves the server" — has one historical
exception, and it still matters: an earlier signing key was hard-coded in this
repo AND wired in production, so the public key `8857880d…` is **burned**: any
lock still holding it accepts tokens anyone with a clone of this repo can mint,
and must be reflashed.

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

## Replay prevention

The lock uses a durable jti store (`jti_store.c` / `jti_store.h`) that retains each
consumed jti until its `exp` passes, then prunes it.  Two properties do the work,
and both are what a volatile or small cache would give away:

| Property | Why it closes a replay path |
|----------|-----------------------------|
| **Durable across power-cycles.** The store is NVS-backed (`nvs_set_blob` / `nvs_get_blob`), so a consumed jti is remembered until its exp passes whatever the lock does in between. | A lock a thief can power-cycle is a lock whose replay window is «until someone pulls the battery», not «until exp». |
| **Sized past the window, and evicts by expiry.** 64 entries (`JTI_STORE_SIZE = 64`), expired entries pruned on every call, and — if the table is genuinely full — the entry soonest to expire is the one evicted, never a random or arbitrary one. | The 15-min TTL bounds the table at one entry per token accepted in that window, so 64 is headroom rather than a limit; and if it were ever reached, dropping the shortest-lived record is the choice that leaves the least replay time on the table. |

**Host test:** the in-memory backend is used for `make test` / `make test-asan`; the
NVS wiring (`nvs_set_blob` / `nvs_get_blob`) is documented in `jti_store.c` and
activates on the ESP32 board when the NVS calls are uncommented. The host-tested
semantics are identical to the NVS-backed version.

---

## Unlocking a flashed board WITHOUT an iPhone

`../bin/ble-unlock` (Python 3, `pip3 install bleak`) writes a rental token
straight to the lock's unlock characteristic over BLE from a Mac or Linux
laptop, so the board can be exercised with no App Clip and no Apple account:

```
../bin/ble-unlock --scooter SK-001 --token "<wire token>"
../bin/ble-unlock --scooter SK-001 --from-server   # SERVER_URL env; mints via the demo
```

It is built against the wire contract above (service `4e2a1000-…`,
characteristic `4e2a1002-…`, UTF-8 token bytes, write-with-response) and is
**UNVERIFIED until run against a real flashed ESP32-C3** — its own header says
so, and the table below is where that status is tracked.

---

## What is and is not proven here

| Claim | Status |
|-------|--------|
| Ed25519-verify in C accepts the known-answer token vector (with domain tag) | **PROVEN** (`make test`) |
| Domain-separation tag check — token with wrong/missing tag rejected | **PROVEN** (`make test`) |
| Expired token (now > exp) rejected | **PROVEN** (`make test`) |
| Wrong scooter_code rejected | **PROVEN** (`make test`) |
| Flipped sig byte rejected | **PROVEN** (`make test`) |
| Oversized sig field (400 base64url chars) → 0, no stack overflow | **PROVEN** (`make test`; `make test-asan` for ASan confirmation) |
| Malformed / truncated / NULL tokens → 0, no crash | **PROVEN** (`make test`) |
| Field count is exactly 6 — a 5-, 7- or 8-field message with a VALID dev-key signature is rejected | **PROVEN** (`make test`) |
| A trailing `|` is a seventh field, not punctuation — validly signed, still rejected | **PROVEN** (`make test`) |
| A pipe in an issuer input shifts fields so `field[4]` reads a caller-chosen expiry — rejected by the count gate | **PROVEN** (`make test`) |
| Field charsets — an empty field, a non-numeric `iat`, a signed or overflowing `exp`, a jti in the wrong alphabet: all rejected with a VALID signature | **PROVEN** (`make test`) |
| `skooti_parse_jti` applies the same field-count and jti-charset gates as `skooti_verify_token`, so the replay store is never keyed on bytes those gates refused | **PROVEN** (`make test`) |
| C verifier accepts a freshly Ruby/OpenSSL-signed token | **PROVEN** (`make crosscheck`) |
| The C verifier, `RentalTokenIssuer.verify` and `LockSim#unlock` give the declared answer on every vector in `token_vectors.rb` | **PROVEN** (`make crosscheck`) |
| jti_store: insert → seen-again → reject; expired entry pruned → re-insert ok | **PROVEN** (`make test` jti-store tests) |
| Durable replay prevention across reboot (NVS backend, host-tested semantics) | **PROVEN** on host (in-memory backend); NVS wiring documented in `jti_store.c`, activates on board |
| BLE GATT advertising + connect + write unlock | **Not yet** — needs board (`../bin/ble-unlock` is the no-Apple harness for this row) |
| GPIO drives relay on valid token | **Not yet** — needs board |
| App Clip → lock BLE end-to-end | **Not yet** — needs board + Apple account |
