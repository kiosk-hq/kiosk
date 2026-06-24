// SkootiClipApp.swift — App Clip entry point
//
// Launch flow:
//   1. User taps an NFC tag / App Clip Code on a scooter.
//   2. iOS decodes the App Clip Code URL: https://skooti.app/unlock?scooter=SK-001
//      (optionally also &token=<JWT>&reservation_id=<uuid> for the demo stub).
//   3. iOS calls onContinueUserActivity with an NSUserActivity whose
//      webpageURL is the decoded URL.
//   4. This handler:
//        a. Parses the scooter code from the URL.
//        b. Resolves the AgentHandoff (token + reservation_id).
//        c. Shows UnlockView and starts the BLE flow.
//
// Associated Domains entitlement:
//   The App Clip target's entitlements file must include:
//     com.apple.developer.associated-domains = ["appclips:skooti.app"]
//   (see appclip/README.md for provisioning steps)
//
// NSBluetoothAlwaysUsageDescription:
//   Must be set in Info.plist (see SkootiClip-Info.plist snippet in appclip/).
//   The string explains why the App Clip needs Bluetooth.

import SwiftUI

@main
struct SkootiClipApp: App {

    // State driving the root view.
    @State private var scooterCode: String = ""
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
            UnlockView(scooterCode: scooterCode, handoff: handoff)
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

        // Parse scooter code from ?scooter=SK-001
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scooterItem = components.queryItems?.first(where: { $0.name == "scooter" }),
              let code = scooterItem.value, !code.isEmpty else {
            launchError = "Missing ?scooter= parameter in launch URL: \(url)"
            return
        }

        guard let resolved = AgentHandoff.from(url: url) else {
            launchError = "Could not resolve agent token / reservation ID."
            return
        }

        scooterCode = code
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
