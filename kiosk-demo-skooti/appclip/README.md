# Skooti App Clip — Build & Provisioning Guide

> **Status (2026-06-25):** XcodeGen project generates cleanly; `xcodebuild`
> compile-check passes (iOS Simulator SDK, no signing).  On-device BLE unlock
> requires a physical iPhone + paid Apple Developer account + the ESP32-C3 board.

---

## How Arch 2 works

```
NFC tag / QR code
  URL: https://skooti.app/unlock?scooter=SK-001&rt=<percent-encoded-wire-token>
       │                           │               │
       │                    scooter code       rental token
       │                    (for BLE scan)     (provider-signed, Ed25519)
       ▼
iOS App Clip launches
       │
       ├─ Parse scooter= and rt= from URL  ← AgentHandoff.from(url:)
       │   URLComponents handles percent-decoding of the rt= value
       │
       ├─ BLE scan for service 4e2a1000-…
       │   Filter: connect ONLY to peripheral named "skooti-SK-001"
       │   (avoids connecting to a wrong scooter when multiple are nearby)
       │
       ├─ Connect + discover unlock char 4e2a1002-…
       ├─ Write rt token (UTF-8) to unlock char  ← no server call
       │
       └─ Lock verifies offline (Ed25519 + domain tag + scooter_code + exp + jti)
          GPIO HIGH 3 s → physically unlocked
```

**No challenge characteristic.  No server round-trip at unlock.**
The rental token is issued by the server at `start_rental` (after pay) and
delivered to the App Clip via the launch URL's `rt=` parameter.
The lock verifies it fully offline.

### Wire token format

```
kiosk-rental-v1|<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>.<base64url(Ed25519 sig)>
```

Field 0 (`kiosk-rental-v1`) is a fixed domain-separation tag — the lock rejects
any token whose field 0 does not exactly match.

---

## Source layout

```
appclip/
  project.yml               — XcodeGen spec (EDIT THIS, not the .xcodeproj)
  Makefile                  — CLI targets: project / build-sim / build-device / open / clean
  .gitignore                — SkootiDemo.xcodeproj/ and build/ are gitignored
  Skooti/
    SkootiApp.swift         — container app @main (trivial placeholder)
    ContentView.swift       — container placeholder screen
    Skooti-Info.plist       — container Info.plist (generated/managed by XcodeGen)
    Skooti.entitlements     — container entitlements (generated/managed by XcodeGen)
  SkootiClip/
    SkootiClipApp.swift     — App Clip @main; parses launch URL; routes to UnlockView
    UnlockView.swift        — SwiftUI screen + UnlockViewModel (drives BLE flow)
    LockBLE.swift           — CBCentralManager; scan → filter by name → connect → write token
    Models.swift            — AgentHandoff, Configuration, UnlockState
    SkootiClip-Info.plist   — App Clip Info.plist (generated/managed by XcodeGen)
    SkootiClip.entitlements — App Clip entitlements (generated/managed by XcodeGen)
  README.md                 — this file
```

> **Important:** `Skooti-Info.plist`, `Skooti.entitlements`, `SkootiClip-Info.plist`,
> and `SkootiClip.entitlements` are written by `xcodegen generate` from the
> `info.properties` and `entitlements.properties` blocks in `project.yml`.
> Edit `project.yml` and re-run `make project` rather than editing those files directly.

---

## Build path A — GUI (Xcode)

**Prerequisites:**
- Xcode 15 or later (tested with Xcode 26.2)
- `brew install xcodegen`
- Paid Apple Developer Program account (required for the App Clip entitlement)

**Steps:**
1. `cd appclip && make project` — generates `SkootiDemo.xcodeproj`
2. `make open` — opens the project in Xcode
3. In Xcode:
   - Select the **Skooti** target → Signing & Capabilities → set your **Team**
   - Select the **SkootiClip** target → Signing & Capabilities → set the same Team
4. Connect a physical iPhone
5. Select the **Skooti** scheme and your device as the destination
6. ⌘R to build and run

App Clip BLE and NFC cannot be tested in the Simulator — a real iPhone is required.

---

## Build path B — CLI

**Prerequisites:**
- Xcode 15+ with iOS 17+ SDK
- `brew install xcodegen`

```bash
cd appclip

# 1. Generate the Xcode project
make project

# 2. Compile-check (Simulator SDK, no signing required)
make build-sim

# 3. Build for device (requires a paid Developer account)
DEVELOPMENT_TEAM=ABCDE12345 make build-device

# 4. Open in Xcode (optional, to set team interactively)
make open

# 5. Clean generated artifacts
make clean
```

### Bundle prefix / team override

The default bundle ID prefix is `app.skooti.demo`.  Override without editing
`project.yml`:

```bash
BUNDLE_PREFIX=app.skooti.personal DEVELOPMENT_TEAM=ABCDE12345 make project
```

---

## Launch trigger reality — what you need and how to test

### Production path (requires skooti.app AASA)

For an NFC tap or App Clip Code scan to launch the clip, iOS fetches
`https://skooti.app/.well-known/apple-app-site-association` and checks that the
`appclips` key matches your App Clip bundle ID.  This requires controlling the
`skooti.app` domain.

Minimal AASA:

```json
{
  "appclips": {
    "apps": ["TEAMID.app.skooti.demo.Clip"]
  },
  "applinks": {
    "apps": [],
    "details": [
      { "appID": "TEAMID.app.skooti.demo", "paths": ["/unlock*"] }
    ]
  }
}
```

### Demo / local path — no domain required

Use a **Local Experience** to bypass the AASA lookup entirely:

1. Build and run the **SkootiClip** target to a registered device from Xcode
2. On the device: **Settings → Developer → Local Experiences → Add Local Experience**
   - URL prefix: `https://skooti.app/unlock`
   - Bundle ID: `app.skooti.demo.Clip`
   - Title: `Skooti Unlock`
3. Launch by scanning a **QR code** that encodes the full token URL

### The QR code must be generated per-rental

The rental token is dynamic (issued by the server at `start_rental` time, 15-min TTL).
It CANNOT be a static sticker on the scooter.  The flow is:

```
Server start_rental → issues rental token
  → assistant encodes: https://skooti.app/unlock?scooter=SK-001&rt=<percent-encoded token>
  → generates a QR code from that URL
  → user scans the QR → iOS shows App Clip banner → clip launches
```

The `|` characters in the token must be percent-encoded (`%7C`) in the URL.
`URLComponents.queryItems` in the clip handles decoding automatically.

On the server side (Ruby):
```ruby
rt_encoded = CGI.escape(rental_token)
url = "https://skooti.app/unlock?scooter=#{scooter_code}&rt=#{rt_encoded}"
```

### NFC tag

Write the percent-encoded URL to an NFC NDEF tag using any NDEF writer app.
Same encoding requirement as QR: the `rt=` value must be percent-encoded.

---

## What is and is not proven

| Claim | Status |
|-------|--------|
| Server Ed25519 rental-token issue + verify chain (register → KYC → reserve → pay → start_rental) | **PROVEN** (`rake demo`, Plan 4.3 T1) |
| Firmware Ed25519 offline verify (v2: domain tag + 6-field parse) + Ruby↔C interop | **PROVEN** (`make test`, Plan 4.3 T2) |
| Durable jti replay prevention (NVS-backed jti_store, 64 entries) | **PROVEN** (`make test` jti-store tests, Plan 4.3 T2) |
| App Clip Swift source compiles (`make build-sim`) | **PROVEN** (xcodebuild, iOS Simulator SDK, 2026-06-25) |
| BLE device-name filtering (scan finds `skooti-SK-001`, not other scooters) | **Code correct; not yet tested on hardware** |
| BLE scan → connect → unlock char discover → write token on ESP32-C3 | **Not yet** — needs board + real iPhone + paid team |
| App Clip Code / NFC / QR launch on iOS | **Not yet** — needs signed build + device + Local Experience |
| Rental token handoff via Shared App Group Keychain (production path) | **Not yet** — URL-param stub in place |

---

## BLE wire contract

| Role | UUID |
|------|------|
| Service | `4e2a1000-5b3c-4b1e-9f8c-6d7e8a9b0c1d` |
| Unlock (WRITE) | `4e2a1002-5b3c-4b1e-9f8c-6d7e8a9b0c1d` |

**Advertised device name:** `skooti-<SCOOTER_CODE>` (e.g. `skooti-SK-001`)
The firmware sets this via `NimBLEDevice::init("skooti-" SCOOTER_CODE)`.
The clip's `LockBLE.scan(scooterCode:)` filters on `"skooti-\(scooterCode)"` via
`CBAdvertisementDataLocalNameKey` (or `peripheral.name` from scan response).

**Unlock write** payload: the raw rental token string (UTF-8), up to ~220 bytes.

**MTU:** NimBLE negotiates MTU 256.  The clip checks
`peripheral.maximumWriteValueLength(for: .withResponse)` and fails with a clear error
if the token exceeds the negotiated limit.

**Foreground BLE only:** App Clips cannot use `bluetooth-central` background mode.
The unlock flow (~5 s) must complete in the foreground.

---

## Provisioning requirements

The App Clip target requires a **paid Apple Developer Program account** ($99/year):
- `com.apple.developer.on-demand-install-capable` entitlement is not available to free teams
- Associated Domains (`appclips:skooti.app`) requires a paid team
- Local Experience testing requires a device registered to a paid team

A **physical iPhone** is required — the Simulator does not support CoreBluetooth
connections to real BLE hardware.

---

## Troubleshooting

**`CBCentralManager` stays in `.unauthorized`**
→ `NSBluetoothAlwaysUsageDescription` missing from Info.plist.
  Re-run `make project` to regenerate the plist from `project.yml`.

**App Clip never launches from QR / NFC**
→ AASA not served, or the Local Experience prefix doesn't match the URL exactly.
  Ensure the URL prefix in Local Experience is `https://skooti.app/unlock` (no trailing slash).

**BLE scan times out / wrong scooter connected**
→ The peripheral's advertised name doesn't match `skooti-<scooterCode>`.
  Check the SCOOTER_CODE `#define` in `skooti_lock.ino` and the serial output.

**Token write rejected / lock stays locked**
→ Check serial output at 115200 baud.  Common causes:
  `exp < DEMO_NOW` (token expired), wrong `scooter_code`, replayed `jti`.

**Token too large (MTU error)**
→ Shorten `reservation_id` or `scooter_code`.  The clip logs exact byte counts.

**`handshake error` / `AgentHandoff returns nil`**
→ The launch URL is missing `scooter=`.  Check the QR URL encoding.
  If `rt=` is absent, the demo stub token is used (may be expired — check `exp` vs `DEMO_NOW`).
