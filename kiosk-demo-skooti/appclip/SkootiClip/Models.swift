// Models.swift — shared data types for the Skooti App Clip (offline Ed25519)
//
// These structs represent the wire contracts with the BLE lock and the launch URL.
// None of them touch UIKit / AppKit — they are pure value types safe to use from
// any context.

import Foundation

// ============================================================
// MARK: — Agent Handoff
// ============================================================
//
// The only values the App Clip needs to unlock are:
//
//   scooterCode   — identifies which lock to BLE-connect to (also embedded in
//                   the token, but used for scanning / UI before writing).
//   rentalToken   — the provider-signed wire token:
//                   "<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>.<base64url(sig)>"
//                   issued by RentalTokenIssuer (server) and carried in the rt= URL param.
//                   The clip writes this string verbatim over BLE; the lock verifies it
//                   offline (Ed25519 + own scooter_code + exp + jti).
//
// PRODUCTION INTEGRATION SEAM
// ─────────────────────────────────────────────────────────────
// The rental token is short-lived (15-min TTL, exp field).  In the reference path it
// travels in the launch URL's rt= parameter — set by the assistant's personal-agent app
// after pay/start_rental, encoded into the NFC tag URL or the App Clip Code deep-link.
//
// Alternative delivery paths (same AgentHandoff struct; only from(url:) changes):
//
//   (a) URL param — reference path (current stub).
//       https://skooti.demo.kiosk.tech/unlock?scooter=SK-001&rt=<wire-token>
//       Simple, works for demos.  The token is single-use + 15-min lived; exposure
//       in logs is bounded by that window.
//
//   (b) Shared App Group Keychain
//       The full Skooti app (which ran register → reserve → pay → start_rental;
//       licence-free scooters have had no KYC leg since K-442 — KYC gates only
//       the combustion motorcycle, see script/rental_flow.rb)
//       writes the rental token into a Keychain item in a shared App Group
//       (e.g. group.app.skooti).  The App Clip reads it on launch.
//       Both targets must declare the same App Group entitlement.
//
//   (c) Server round-trip: the App Clip authenticates (Face ID / passkey), then
//       calls a Skooti endpoint that issues (or looks up) the pending rental token
//       scoped to (scooter, user).  No token travels in the URL at all.
//
// Swap only AgentHandoff.from(url:) for option (b) or (c) without changing any other
// file.
// ─────────────────────────────────────────────────────────────

struct AgentHandoff {
    /// The scooter's short identifier (e.g. "SK-001"), parsed from the URL scooter= param.
    let scooterCode: String
    /// The provider-signed rental token (wire format), from the URL rt= param.
    /// Written verbatim as UTF-8 bytes to the lock's unlock BLE characteristic.
    let rentalToken: String

    // STUB — reads scooter + rt from launch URL query params.
    // Replace with Keychain / server round-trip for option (b) or (c).
    static func from(url: URL) -> AgentHandoff? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }

        let params = Dictionary(uniqueKeysWithValues:
            items.compactMap { item -> (String, String)? in
                guard let value = item.value, !value.isEmpty else { return nil }
                return (item.name, value)
            }
        )

        // scooter= is always required.
        guard let scooterCode = params["scooter"] else { return nil }

        // rt= is the rental token (offline reference path).
        if let rt = params["rt"] {
            return AgentHandoff(scooterCode: scooterCode, rentalToken: rt)
        }

        // Fall back to a hard-coded demo stub when rt= is absent, so the UI can be
        // exercised with a Local Experience URL that doesn't yet carry a real token.
        // DEMO ONLY — remove or replace before any on-device test against real hardware.
        return Configuration.demoHandoff(scooterCode: scooterCode)
    }
}

// ============================================================
// MARK: — Configuration
// ============================================================
//
// Centralises the few constants that vary between dev / staging / production.
// In Xcode these would typically be set via an xcconfig or a Build Setting
// injected into Info.plist; here they are plain Swift constants for clarity.

enum Configuration {
    /// Base URL of the Kiosk provider (kiosk-demo-skooti) — the SAME host the
    /// two entitlements declare and appclip/README.md uses throughout. Point it
    /// at your own origin for a real deployment; the value here names a host
    /// this project actually serves rather than an invented one (K-719).
    static let kioskBaseURL = URL(string: "https://skooti.demo.kiosk.tech")!

    // ── DEMO STUB ─────────────────────────────────────────────
    // A hard-coded rental token used when the launch URL does not carry rt=.
    // This is the test-vector token from Plan 4.2 T1 (SCOOTER_CODE=SK-001).
    // It will only verify on the lock if DEMO_NOW < 1750000900 (the exp).
    //
    // REPLACE with a freshly-issued token before any on-device test.
    static func demoHandoff(scooterCode: String) -> AgentHandoff {
        AgentHandoff(
            scooterCode: scooterCode,
            rentalToken: "SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899" +
                         ".b-8ZCqcN1FZAXn4YbXPJXasTED2rwq0DSOXrcRSjI9ajReEBb9Y3m3YSHgNJEElC" +
                         "HSwnEGGYbNGiEWRCZD_yBw"
        )
    }
}

// ============================================================
// MARK: — BLE state
// ============================================================

/// Tracks the App Clip's progress through the offline unlock flow.
///
/// Flow: idle → scanning → connecting → discovering → writingToken → unlocked
///                                                  ↘ failed(reason:)
enum UnlockState: Equatable {
    case idle
    case scanning
    case connecting
    /// Connected; discovering SKOOTI service + unlock characteristic.
    case discovering
    /// Characteristics found; ViewModel is about to call writeToken(rentalToken:).
    case discovered
    /// Rental token has been written to the lock (write dispatched).
    case writingToken
    /// CoreBluetooth confirmed the ATT write; command delivered to the lock.
    case unlocked
    case failed(reason: String)
}
