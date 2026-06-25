// SkootiClipApp.swift — App Clip entry point (Arch 2)
//
// Launch flow:
//   1. User taps an NFC tag / App Clip Code on a scooter.
//   2. iOS decodes the URL: https://skooti.app/unlock?scooter=SK-001&rt=<wire-token>
//   3. iOS calls onContinueUserActivity with an NSUserActivity whose
//      webpageURL is the decoded URL.
//   4. This handler:
//        a. Parses scooter= and rt= from the URL via AgentHandoff.from(url:).
//        b. Shows UnlockView and starts the BLE flow.
//
// The rt= parameter carries the provider-signed rental token (Arch 2):
//   "<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>.<base64url(sig)>"
// The assistant's personal-agent app obtains this token after pay/start_rental
// and encodes it into the NFC tag URL / App Clip Code deep-link.  The App Clip
// writes it verbatim to the lock over BLE; the lock verifies it offline (Ed25519).
// No server call is made at unlock time.
//
// AgentHandoff integration seam:
//   Reference path: rt= in the URL (current implementation).
//   Alternative A:  Shared App Group Keychain — the full app writes the token after
//                   start_rental; the Clip reads it on launch.
//   Alternative B:  Server round-trip — the Clip authenticates (Face ID/passkey) and
//                   calls a Skooti endpoint that issues or looks up the pending token.
//   Swap only AgentHandoff.from(url:) for A or B; no other file changes needed.
//
// Associated Domains entitlement:
//   The App Clip target's entitlements file must include:
//     com.apple.developer.associated-domains = ["appclips:skooti.app"]
//   (see appclip/README.md for provisioning steps)
//
// NSBluetoothAlwaysUsageDescription:
//   Must be set in Info.plist (see SkootiClip-Info.plist snippet in appclip/).

import SwiftUI

@main
struct SkootiClipApp: App {

    // State driving the root view.
    @State private var handoff: AgentHandoff? = nil
    @State private var launchError: String? = nil

    var body: some Scene {
        WindowGroup {
            rootView
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb, perform: handleActivity)
        }
    }

    // ── Root view ─────────────────────────────────────────────

    @ViewBuilder
    private var rootView: some View {
        if let handoff {
            UnlockView(handoff: handoff)
        } else if let error = launchError {
            LaunchErrorView(message: error)
        } else {
            // Shown briefly before the UserActivity arrives (or if launched
            // directly in the Simulator without a URL).
            ProgressView("Loading…")
        }
    }

    // ── UserActivity handler ──────────────────────────────────

    private func handleActivity(_ activity: NSUserActivity) {
        guard let url = activity.webpageURL else {
            launchError = "No launch URL found."
            return
        }

        guard let resolved = AgentHandoff.from(url: url) else {
            launchError = "Missing or invalid ?scooter= parameter in launch URL: \(url)\n" +
                          "Expected: https://skooti.app/unlock?scooter=SK-001&rt=<token>"
            return
        }

        handoff = resolved
    }
}

// ============================================================
// MARK: — LaunchErrorView
// ============================================================

/// Shown when the launch URL is malformed or handoff resolution fails.
/// In a production App Clip this would offer a fallback (e.g. open the full app).
struct LaunchErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Launch error")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}
