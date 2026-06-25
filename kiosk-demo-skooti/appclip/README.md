# Skooti App Clip — Build & Provisioning Guide

> **Status:** Sources written for Arch 2 (offline Ed25519 token); NOT compiled here
> (no Xcode / Apple account in the build environment).  Server chain and firmware
> crypto are proven (Plan 4.2 T1–T3).  On-device BLE and the launch flow are to be
> validated by Phil when the board + Apple Developer account are ready.

---

## How Arch 2 works

```
NFC tag / App Clip Code
  URL: https://skooti.app/unlock?scooter=SK-001&rt=<wire-token>
       │                           │               │
       │                    scooter code       rental token
       │                    (for BLE scan)     (provider-signed)
       ▼
  iOS App Clip launches
       │
       ├─ Parse scooter= and rt= from URL  ← AgentHandoff.from(url:)
       │
       ├─ BLE scan for service 4e2a1000-…
       ├─ Connect + discover unlock char 4e2a1002-…
       ├─ Write rt token (UTF-8) to unlock char  ← no server call
       │
       └─ Lock verifies offline (Ed25519 + scooter_code + exp + jti)
          GPIO HIGH 3 s → physically unlocked
```

**No challenge characteristic.  No server round-trip at unlock.**
The rental token is issued by the server at `start_rental` (after pay) and
delivered to the App Clip via the launch URL's `rt=` parameter.
The lock verifies it fully offline.

### Wire token format (identical across server / lock-sim / firmware / clip)

```
<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>.<base64url(Ed25519 sig)>
```

Split on the **last** `.`; the left side is the signed message; the right side is
the 64-byte Ed25519 signature, base64url-encoded without padding.

---

## Source layout

```
appclip/
  SkootiClip/
    SkootiClipApp.swift   — @main entry; parses launch URL (scooter= + rt=), routes to UnlockView
    UnlockView.swift      — SwiftUI screen + UnlockViewModel (drives the BLE flow)
    LockBLE.swift         — CBCentralManager wrapper; scan → connect → discover → write token
    Models.swift          — value types: AgentHandoff, Configuration, UnlockState
    SkootiClip-Info.plist — required keys snippet (NSBluetoothAlwaysUsageDescription)
    SkootiClip.entitlements — Associated Domains + on-demand-install-capable
  README.md               — this file
```

---

## Prerequisites

### Apple Developer Program ($99 / year) — REQUIRED

App Clips cannot be built, signed, or tested without a **paid Apple Developer Program
membership**.  Specifically:

- The **App Clip target** requires the `com.apple.developer.on-demand-install-capable`
  entitlement, which is only available to paid teams.
- **Associated Domains** (`appclips:skooti.app`) requires a paid team.  A free personal
  team (the kind you get by signing in with an Apple ID in Xcode without paying) cannot
  sign the entitlement.
- The **Local Experience** developer tool (the way to test without App Store Connect)
  requires a device registered to a paid team.

A **physical iPhone** is also required — the Simulator does not support CoreBluetooth
connections to real BLE hardware.

---

## Step 1 — Create the Xcode project

1. Open Xcode → **File → New → Project** → **iOS → App**.
   - Product Name: `Skooti`
   - Bundle Identifier: `app.skooti.personal` (or your domain)
   - Language: Swift, Interface: SwiftUI
   - Minimum deployment: iOS 16+

2. **Add the App Clip target:**
   - File → New → Target → **App Clip**
   - Product Name: `SkootiClip`
   - Bundle Identifier: `app.skooti.personal.Clip`
     (must be the parent app bundle ID + `.Clip` — Apple enforces this)

3. Copy the `SkootiClip/` source files into the new target:
   - Add all `.swift` files to the `SkootiClip` target membership.
   - Do NOT add them to the parent app target.

4. Set the **Code Signing Entitlements** for the App Clip target:
   - Build Settings → Code Signing → Code Signing Entitlements → `SkootiClip.entitlements`

---

## Step 2 — App ID + Associated Domains in the Developer Portal

1. Sign in to [developer.apple.com](https://developer.apple.com).
2. Identifiers → **+** → App IDs → App.
   - Description: `Skooti`
   - Bundle ID: `app.skooti.personal`
   - Capabilities: ✅ **Associated Domains**
3. Identifiers → **+** → App IDs → App Clip.
   - Description: `SkootiClip`
   - Bundle ID: `app.skooti.personal.Clip`
   - Capabilities: ✅ **Associated Domains**
4. Create **provisioning profiles** for both IDs (Development).

---

## Step 3 — apple-app-site-association (AASA) file

iOS fetches this file from `https://skooti.app/.well-known/apple-app-site-association`
(or `https://skooti.app/apple-app-site-association`) before it will launch your App Clip.

The file must be:
- Served over HTTPS with a valid certificate.
- `Content-Type: application/json` (no `.json` extension in the URL).
- Include an `appclips` key pointing to your App Clip bundle ID.

Minimal example:

```json
{
  "appclips": {
    "apps": ["TEAMID.app.skooti.personal.Clip"]
  },
  "applinks": {
    "apps": [],
    "details": [
      {
        "appID": "TEAMID.app.skooti.personal",
        "paths": ["/unlock*"]
      }
    ]
  }
}
```

Replace `TEAMID` with your 10-character Apple Team ID (visible in the portal under
Membership).

**For the demo:** if you don't yet control `skooti.app`, test with a Local Experience
(Step 5 below) — iOS bypasses the AASA check for local experiences.

---

## Step 4 — NSBluetoothAlwaysUsageDescription in Info.plist

Open the App Clip target's Info plist (Xcode target editor → Info tab) and add:

| Key | Type | Value |
|-----|------|-------|
| `NSBluetoothAlwaysUsageDescription` | String | `Skooti needs Bluetooth to connect to the scooter lock and unlock it.` |

Without this key iOS will refuse to present the Bluetooth permission dialog and
`CBCentralManager` will report `.unauthorized` immediately — the BLE flow won't start.

Also verify **no** `UIBackgroundModes` entry for `bluetooth-central` is added:
App Clips cannot use background BLE.  The unlock flow (~5 s) must complete in
the foreground.

---

## Step 5 — Test without App Store Connect: Local Experience

A **Local Experience** lets you test the App Clip on a registered device without
publishing to App Store Connect or even building an archive.

1. Build and run the App Clip target on your device from Xcode (⌘R with the
   `SkootiClip` scheme selected and your iPhone as the destination).
2. On the **device**, go to **Settings → Developer → Local Experiences → Add Local
   Experience**.
   - URL prefix: `https://skooti.app/unlock`
   - Bundle ID: `app.skooti.personal.Clip`
   - App Clip experience title: `Skooti Unlock`
3. Simulate an NFC tap or App Clip Code scan:
   - In the **Camera** app, point at an NFC Tag / App Clip Code.
   - Or use `xcrun simctl openurl booted "https://skooti.app/unlock?scooter=SK-001&rt=<token>"`
     for the Simulator (no BLE hardware available in the Simulator).

The Local Experience overrides the AASA lookup — iOS trusts the local mapping
without the live `skooti.app` domain being configured.

---

## Step 6 — Map an NFC Tag / App Clip Code to the launch URL

### NFC Tag

Write the URL `https://skooti.app/unlock?scooter=SK-001&rt=<rental-token>` to an NFC
NDEF tag using the NFC Tools app on iOS or any NDEF writer.

The rental token is issued by the server after `pay` / `start_rental` and placed into
the URL.  For the demo you can write a URL with the test-vector token from Plan 4.2 T1.

When a user taps the tag with iOS 14+, the system reads the URL, matches it against
registered App Clips / Associated Domains, and shows the App Clip banner.

### App Clip Code

Generate an App Clip Code in App Store Connect (Codes section, under your app's
App Clip experience).  Each code embeds a URL and an NFC payload.  For per-rental
tokens the URL must be dynamic (generated at start_rental time) — encode it in a QR
code rather than a static App Clip Code.

---

## Rental token handoff (integration seam)

The App Clip needs two values:

| Value | URL param | Source |
|-------|-----------|--------|
| scooter code | `scooter=` | NFC tag / App Clip Code URL |
| rental token | `rt=` | server `start_rental` response |

**Reference path (current implementation in `Models.swift`):**
`AgentHandoff.from(url:)` reads `scooter=` and `rt=` from URL query params:

```
https://skooti.app/unlock?scooter=SK-001&rt=SK-001|resv-1|1750000000|1750000900|aabb….<sig>
```

The rental token is short-lived (15-min TTL embedded in `exp`).  Within that window
the token appearing in a URL is acceptable — it's single-use (jti) and the lock
rejects it after the first successful write.

**Alternative A — Shared App Group Keychain:**
The full Skooti app (which ran register → KYC → reserve → pay → start_rental) writes
the rental token into a Keychain item in a shared App Group (e.g. `group.app.skooti`).
The App Clip reads it on launch, ignoring the `rt=` param entirely.

```swift
// Full app writes (after start_rental):
KeychainHelper.write(key: "rental_token",  value: rentalToken,  accessGroup: "group.app.skooti")
KeychainHelper.write(key: "scooter_code",  value: scooterCode,  accessGroup: "group.app.skooti")

// App Clip reads (in AgentHandoff.from(url:)):
let token = KeychainHelper.read(key: "rental_token", accessGroup: "group.app.skooti")
```

Both targets must declare the same App Group entitlement
(`com.apple.security.application-groups = ["group.app.skooti"]`).

**Alternative B — Server round-trip at clip launch:**
The clip authenticates (Face ID / passkey), then calls a Skooti endpoint that issues
or looks up the pending rental token for (scooter, user).  No token travels in the URL.

Swap only `AgentHandoff.from(url:)` for alternative A or B; no other file changes needed.

---

## BLE wire contract (cross-checked against firmware/skooti_lock.ino)

| Role | UUID |
|------|------|
| Service | `4e2a1000-5b3c-4b1e-9f8c-6d7e8a9b0c1d` |
| Unlock (WRITE) | `4e2a1002-5b3c-4b1e-9f8c-6d7e8a9b0c1d` |

**Unlock write** payload: the raw rental token string, UTF-8 encoded, up to ~220 bytes.

```
SK-001|resv-abc123|1750000000|1750000900|aabbccddeeff00112233445566778899.<base64url_sig>
```

The App Clip writes the token with `CBPeripheral.writeValue(_:for:type:.withResponse)`.
CoreBluetooth confirms the ATT write; the lock then verifies offline and drives the GPIO.
There is **no BLE read-back of the verify result** — "write acknowledged" = "command
delivered".  On success the user will see the LED or hear the relay within ~1 s.

**MTU:** NimBLE on the lock negotiates MTU 256.  A typical token is ~180–220 bytes.
The clip checks `peripheral.maximumWriteValueLength(for: .withResponse)` and fails
with a clear error if the token is too large.  In practice iOS negotiates ≥ 185 bytes
with a nearby BLE 4.2+ peripheral.

**Foreground BLE only:** App Clips cannot use `bluetooth-central` background mode.
The lock's GPIO stays high for 3 s after a valid token; the user should engage the
scooter within that window.

---

## What is and is not proven

| Claim | Status |
|-------|--------|
| Server Ed25519 rental-token issue + verify chain (register → KYC → reserve → pay → start_rental) | **PROVEN** (`rake demo`, Plan 4.2 T2) |
| Firmware Ed25519 offline verify + Ruby↔C interop over shared vectors | **PROVEN** (`make test`, Plan 4.2 T3) |
| App Clip Swift source compiles | **Not yet** — requires Xcode + Apple account |
| BLE scan → connect → unlock characteristic discover → write token on a real ESP32-C3 | **Not yet** — needs board + on-device build |
| App Clip Code / NFC launch on iOS | **Not yet** — needs signed build + device |
| Rental token handoff via Shared App Group Keychain (production path A) | **Not yet** — URL-param stub in place |

---

## Troubleshooting

**CBCentralManager stays in `.unauthorized`**
→ `NSBluetoothAlwaysUsageDescription` missing from Info.plist.

**App Clip never launches from NFC tag**
→ AASA not served at `skooti.app/.well-known/apple-app-site-association`, or
  the `appclips` key is wrong.  Use Local Experience to bypass during development.

**`handshake error` / `AgentHandoff returns nil`**
→ The launch URL is missing `scooter=` or carries no `rt=` and the demo stub token
  doesn't match the lock's `exp` window.  Use `xcrun simctl openurl` with a fresh token.

**Token write rejected / lock stays locked**
→ Check serial output at 115200 baud.  Common causes: `exp < DEMO_NOW` (token expired),
  wrong `scooter_code` in the token, or replayed `jti`.

**Token too large (MTU error)**
→ The negotiated MTU was smaller than the token.  Shorten `reservation_id` or reduce
  `scooter_code` length.  The clip logs the exact byte counts.

**`Failed to connect` immediately**
→ The iPhone is more than ~10 m from the scooter, or the firmware crashed.
  Check the serial monitor at 115200 baud.
