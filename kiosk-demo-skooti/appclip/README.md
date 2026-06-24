# Skooti App Clip — Build & Provisioning Guide

> **Status:** Sources written; NOT compiled here (no Xcode / Apple account in the build
> environment).  The server chain and firmware crypto are proven (see Part B + C).
> On-device BLE and the launch flow are to be validated by Phil when the board +
> Apple Developer account are ready.

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

## Source layout

```
appclip/
  SkootiClip/
    SkootiClipApp.swift        — @main entry; parses launch URL, routes to UnlockView
    UnlockView.swift           — SwiftUI screen + UnlockViewModel (drives the BLE flow)
    LockBLE.swift              — CBCentralManager wrapper; scan → connect → read → write
    KioskClient.swift          — POST /kiosk/exec to fetch the HMAC MAC
    Models.swift               — value types: AgentHandoff, Configuration, UnlockState, …
    SkootiClip-Info.plist      — required keys snippet (NSBluetoothAlwaysUsageDescription)
    SkootiClip.entitlements    — Associated Domains + on-demand-install-capable
  README.md                    — this file
```

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
3. Now simulate an NFC tap or App Clip Code scan:
   - In the **Camera** app, point at an NFC Tag / App Clip Code.
   - Or use the Xcode Simulator's **Features → Trigger iCloud Link** with the URL.
   - Or use `xcrun simctl openurl booted "https://skooti.app/unlock?scooter=SK-001"` for
     the Simulator (no BLE hardware available in the Simulator).

The Local Experience overrides the AASA lookup — iOS trusts the local mapping
without the live `skooti.app` domain being configured.

---

## Step 6 — Map an NFC Tag / App Clip Code to the launch URL

### NFC Tag

Write the URL `https://skooti.app/unlock?scooter=SK-001` to an NFC NDEF tag:

```sh
# Using the NFC Tools app on iOS, or any NDEF writer:
#   Record type: URI
#   Value:       https://skooti.app/unlock?scooter=SK-001
```

When a user taps the tag with iOS 14+, the system reads the URL, matches it against
registered App Clips / Associated Domains, and shows the App Clip banner.

### App Clip Code

Generate an App Clip Code in App Store Connect (Codes section, under your app's
App Clip experience).  Each code embeds the URL and an NFC payload.  The code
is printed / displayed on the scooter.

For the demo the NFC tag approach is simpler — no App Store Connect needed.

---

## Agent token + reservation_id handoff (integration seam)

The App Clip needs two values before it can call the Kiosk server:

| Value | Source in production |
|-------|----------------------|
| `bearer_token` | Agent's JWT from the Kiosk registration |
| `reservation_id` | UUID from the `reserve` Action |

**Demo stub (current implementation in `Models.swift`):**
`AgentHandoff.from(url:)` reads these from URL query params:

```
https://skooti.app/unlock?scooter=SK-001&token=<JWT>&reservation_id=<uuid>
```

This is acceptable for a demo — put the token in the NFC URL or the Local Experience URL.
It is NOT suitable for production (token appears in server logs / browser history).

**Production option A — Shared App Group Keychain:**
The full Skooti app (which ran the register → KYC → reserve → pay flow) writes
`bearer_token` and `reservation_id` into a Keychain item in a shared App Group
(e.g. `group.app.skooti`).  The App Clip reads it on launch.

```swift
// Full app writes:
KeychainHelper.write(key: "unlock_handoff", value: handoffJSON,
                     accessGroup: "group.app.skooti")

// App Clip reads (in AgentHandoff.from(url:)):
let data = KeychainHelper.read(key: "unlock_handoff",
                                accessGroup: "group.app.skooti")
```

Both targets must declare the same App Group entitlement
(`com.apple.security.application-groups = ["group.app.skooti"]`).

**Production option B — Server-issued single-use unlock token:**
The full app tells the Skooti server "user X wants to unlock scooter SK-001 now."
The server issues a short-lived (5-min TTL) single-use token.  The App Clip
presents Face ID / passkey, exchanges it for the token, then proceeds.  No
secrets travel in URLs.

Swap `AgentHandoff.from(url:)` for either option without touching any other file.

---

## BLE wire contract (cross-checked against firmware)

The App Clip uses these UUIDs, verbatim from `firmware/skooti_lock.ino`:

| | UUID |
|-|------|
| Service | `4e2a1000-5b3c-4b1e-9f8c-6d7e8a9b0c1d` |
| Challenge (READ+NOTIFY) | `4e2a1001-5b3c-4b1e-9f8c-6d7e8a9b0c1d` |
| Unlock (WRITE) | `4e2a1002-5b3c-4b1e-9f8c-6d7e8a9b0c1d` |

**Challenge read** returns 32 ASCII lowercase hex chars (one-shot nonce).

**Unlock write** payload (ASCII, UTF-8, pipe-delimited):

```
<reservation_id>|<64-char-mac-hex>
```

Example: `resv-abc123|896eec16ca0d164293762269f0d34c319a41b4a463bedc2ce11f3269a49e9b1f...`

This matches `UnlockCallbacks::onWrite` in `skooti_lock.ino` (line ~186), which splits
on the first `|` and calls `skooti_verify_unlock(K_LOCK, SCOOTER_CODE, pending_nonce_hex,
reservation_id, mac_hex)`.

**Foreground BLE only:** App Clips cannot use `bluetooth-central` background mode.
The lock's GPIO stays high for 3 s after a valid MAC; the user should physically
engage the scooter within that window.

---

## Server call (cross-checked against unlock_flow.rb)

```http
POST https://skooti.app/kiosk/exec
Authorization: Bearer <agent_token>
Content-Type: application/json

{
  "command": "run",
  "body": {
    "name":           "unlock",
    "nonce":          "<32 lowercase hex chars from BLE challenge>",
    "reservation_id": "<uuid>"
  }
}
```

Response (HTTP 200):

```json
{
  "value": {
    "mac": "<64 lowercase hex chars>",
    "alg": "HMAC-SHA256"
  }
}
```

This matches `unlock_flow.rb` lines 194–205 (the `post_json` call to `/kiosk/exec`).

---

## What is and is not proven

| Claim | Status |
|-------|--------|
| Server HMAC chain (register → KYC → reserve → pay → unlock) | **PROVEN** (`rake demo`, Part B) |
| Firmware HMAC-SHA256 matches Ruby/OpenSSL over shared vectors | **PROVEN** (`make test`, Part C) |
| App Clip Swift source compiles | **Not yet** — requires Xcode + Apple account |
| BLE scan → connect → challenge read → unlock write on a real ESP32-C3 | **Not yet** — needs board + on-device build |
| App Clip Code / NFC launch on iOS | **Not yet** — needs signed build + device |
| Agent handoff via shared Keychain (production path) | **Not yet** — stub (URL params) in place |

---

## Troubleshooting

**CBCentralManager stays in `.unauthorized`**
→ `NSBluetoothAlwaysUsageDescription` missing from Info.plist.

**App Clip never launches from NFC tag**
→ AASA not served at `skooti.app/.well-known/apple-app-site-association`, or
  the `appclips` key is wrong.  Use Local Experience to bypass during development.

**Unlock write times out / lock doesn't respond**
→ Check that `NimBLEDevice::setMTU(185)` in the firmware is sufficient for
  `reservation_id + "|" + 64-char-mac` (max ~150 bytes).  If the reservation_id
  is longer, bump the MTU or use a write-without-response and check serial output.

**`Failed to connect` immediately**
→ The iPhone is more than ~10 m from the scooter, or the firmware crashed.
  Check the serial monitor at 115200 baud.
