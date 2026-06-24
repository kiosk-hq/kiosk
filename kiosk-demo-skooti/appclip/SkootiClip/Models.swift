// Models.swift — shared data types for the Skooti App Clip
//
// These structs represent the wire contracts with the Kiosk server
// and the BLE handshake state machine.  None of them touch UIKit /
// AppKit — they are pure value types safe to use from any context.

import Foundation

// ============================================================
// MARK: — Agent Handoff
// ============================================================
//
// The App Clip needs two pieces of identity before it can contact
// the Kiosk server:
//
//   bearer_token    — the agent's access_token (JWT) issued by the
//                     Kiosk provider when the user registered.
//   reservation_id  — the UUID that the personal-agent app obtained
//                     after running the "reserve" Action.
//
// PRODUCTION INTEGRATION SEAM
// ─────────────────────────────────────────────────────────────
// In production the user's personal-agent app (which did the full
// register → KYC → reserve → pay flow) hands the App Clip these two
// values via ONE of:
//
//   (a) Shared App Group Keychain
//       Both the full app (bundle: app.skooti.personal) and the
//       App Clip target (bundle: app.skooti.personal.Clip) belong
//       to the same App Group (e.g. group.app.skooti).  The full app
//       writes the token + reservation_id into the shared Keychain
//       item; the App Clip reads it on launch.
//
//   (b) Encoded in the launch URL (demo/testing convenience only)
//       https://skooti.app/unlock?scooter=SK-001
//                                &token=<JWT>
//                                &reservation_id=<uuid>
//       Acceptable for a demo or a short-lived deep-link QR code;
//       NOT suitable for production (token visible in server logs /
//       browser history).
//
//   (c) A server round-trip: the App Clip authenticates the device
//       (Face ID / passkey), then calls a Skooti endpoint that issues
//       a one-time unlock token scoped to (scooter, user, 5-min TTL).
//
// The stub below reads from the launch URL (option b) so the demo
// works end-to-end without the full app installed.  Swap the
// implementation of AgentHandoff.from(url:) for option (a) or (c)
// without changing any other file.
// ─────────────────────────────────────────────────────────────

struct AgentHandoff {
    /// Bearer token (JWT) from the Kiosk agent registration.
    let bearerToken: String
    /// Reservation UUID returned by the "reserve" Action.
    let reservationId: String

    // STUB — reads token + reservation_id from launch URL query params.
    // Replace with Keychain / server round-trip in production.
    static func from(url: URL) -> AgentHandoff? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }

        let params = Dictionary(uniqueKeysWithValues:
            items.compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            }
        )

        guard let token = params["token"],
              let reservationId = params["reservation_id"] else {
            // Fall back to a hard-coded demo stub so the UI can be
            // exercised without the full query params present.
            // DEMO ONLY — remove before any real deployment.
            return Configuration.demoHandoff
        }
        return AgentHandoff(bearerToken: token, reservationId: reservationId)
    }
}

// ============================================================
// MARK: — Configuration
// ============================================================
//
// Centralises the few constants that vary between dev / staging /
// production.  In Xcode these would typically be set via an xcconfig
// or a Build Setting injected into Info.plist; here they are plain
// Swift constants for clarity.

enum Configuration {
    /// Base URL of the Kiosk provider (kiosk-demo-skooti).
    /// Change for production: e.g. "https://skooti.app"
    static let kioskBaseURL = URL(string: "https://skooti.app")!

    // ── DEMO STUB ─────────────────────────────────────────────
    // Hard-coded token + reservation_id used when the launch URL
    // does not carry them.  This makes the UI testable with a
    // Local Experience even without a running server.
    //
    // REPLACE with real values (or remove the fallback) before
    // any on-device test against a real Kiosk server.
    static let demoHandoff = AgentHandoff(
        bearerToken: "REPLACE_ME_demo_bearer_token",
        reservationId: "REPLACE_ME_demo_reservation_uuid"
    )
}

// ============================================================
// MARK: — Kiosk server response types
// ============================================================

/// Successful response from POST /kiosk/exec {command:"run", body:{name:"unlock",…}}
struct UnlockResponse: Decodable {
    struct Value: Decodable {
        /// 64 lowercase hex chars — HMAC-SHA256 the lock will verify.
        let mac: String
        /// "HMAC-SHA256" — informational; not used by the App Clip.
        let alg: String?
    }
    let value: Value
}

// ============================================================
// MARK: — BLE state
// ============================================================

/// Tracks the App Clip's progress through the unlock flow.
enum UnlockState: Equatable {
    case idle
    case scanning
    case connecting
    case readingChallenge
    case fetchingMAC(nonce: String)
    case writingUnlock
    case unlocked
    case failed(reason: String)
}
