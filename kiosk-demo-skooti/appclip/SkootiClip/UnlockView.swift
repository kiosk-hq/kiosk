// UnlockView.swift — the single screen of the Skooti App Clip (offline Ed25519)
//
// Layout:
//   • Scooter code from the launch URL (e.g. "SK-001")
//   • Status indicator reflecting UnlockState
//   • Animated progress / success / failure affordances
//
// The ViewModel lives here (small enough to keep in one file) and drives
// the offline BLE flow:
//
//   scan → connect → discover → write token → unlocked
//
// No server call at unlock time.  The rental token arrives in handoff.rentalToken
// (parsed from the launch URL rt= param by AgentHandoff.from(url:)).
//
// UI is intentionally minimal — App Clips must be < 15 MB and should feel instant.

import SwiftUI

// ============================================================
// MARK: — UnlockViewModel
// ============================================================

@MainActor
final class UnlockViewModel: ObservableObject {

    @Published var displayState: UnlockState = .idle
    @Published var scooterCode: String = ""
    @Published var errorMessage: String?

    private let ble = LockBLE()
    private var handoff: AgentHandoff?
    private var observation: Task<Void, Never>?

    // Call once when the App Clip launches (from SkootiClipApp.onContinueUserActivity).
    func start(handoff: AgentHandoff) {
        self.handoff = handoff
        self.scooterCode = handoff.scooterCode
        errorMessage = nil

        // Observe the LockBLE state and drive the next step of the flow.
        observation = Task { [weak self] in
            guard let self else { return }
            for await bleState in await observeBLEState() {
                await self.handle(bleState: bleState)
            }
        }

        ble.scan(scooterCode: handoff.scooterCode)
    }

    // ── BLE state → flow step ──────────────────────────────────

    private func handle(bleState: UnlockState) async {
        displayState = bleState

        switch bleState {
        case .discovered:
            // Characteristics found — write the rental token straight to the lock.
            guard let handoff else {
                displayState = .failed(reason: "No rental token available")
                return
            }
            ble.writeToken(rentalToken: handoff.rentalToken)

        case .failed(let reason):
            errorMessage = reason

        default:
            break
        }
    }

    // Converts the @Published property to an AsyncSequence for structured concurrency.
    private func observeBLEState() async -> AsyncStream<UnlockState> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }
                var previous: UnlockState = .idle
                while true {
                    let current = ble.state
                    if current != previous {
                        previous = current
                        continuation.yield(current)
                        if case .unlocked = current { continuation.finish(); break }
                        if case .failed   = current { continuation.finish(); break }
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms poll
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// ============================================================
// MARK: — UnlockView
// ============================================================

struct UnlockView: View {
    @StateObject private var vm = UnlockViewModel()

    // Supplied by SkootiClipApp via the resolved AgentHandoff.
    let handoff: AgentHandoff

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 32) {
                headerSection
                statusSection
                if case .failed = vm.displayState {
                    retryButton
                }
            }
            .padding(24)
        }
        .onAppear {
            vm.start(handoff: handoff)
        }
    }

    // ── Header ────────────────────────────────────────────────

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "scooter")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.primary)
            Text("Skooti")
                .font(.largeTitle.bold())
            Text(vm.scooterCode)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    // ── Status ────────────────────────────────────────────────

    private var statusSection: some View {
        VStack(spacing: 16) {
            statusIcon
            Text(statusText)
                .font(.headline)
                .multilineTextAlignment(.center)
                .animation(.default, value: vm.displayState)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch vm.displayState {
        case .idle, .scanning, .connecting, .discovering, .discovered, .writingToken:
            ProgressView()
                .scaleEffect(1.5)
                .padding()
        case .unlocked:
            Image(systemName: "lock.open.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)
        }
    }

    private var statusText: String {
        switch vm.displayState {
        case .idle:              return "Preparing…"
        case .scanning:          return "Looking for scooter…"
        case .connecting:        return "Connecting…"
        case .discovering:       return "Discovering services…"
        case .discovered:        return "Sending unlock token…"
        case .writingToken:      return "Unlocking…"
        case .unlocked:          return "Unlocked! Ride safely."
        case .failed(let reason): return reason
        }
    }

    // ── Retry ─────────────────────────────────────────────────

    private var retryButton: some View {
        Button("Try again") {
            vm.start(handoff: handoff)
        }
        .buttonStyle(.borderedProminent)
    }
}
