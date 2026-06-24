// UnlockView.swift — the single screen of the Skooti App Clip
//
// Layout:
//   • Scooter code extracted from the launch URL (e.g. "SK-001")
//   • Status indicator reflecting UnlockState
//   • Animated progress / success / failure affordances
//
// The ViewModel lives here (small enough to keep in one file) and
// drives the BLE + server flow sequentially:
//
//   scan → connect → readChallenge → fetchMAC → writeUnlock → unlocked
//
// UI is intentionally minimal — App Clips must be < 15 MB and should
// feel instant.

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
    private let client = KioskClient()
    private var handoff: AgentHandoff?
    private var observation: Task<Void, Never>?

    // Call once when the App Clip launches (from SkootiClipApp.onContinueUserActivity).
    func start(scooterCode: String, handoff: AgentHandoff) {
        self.scooterCode = scooterCode
        self.handoff = handoff
        errorMessage = nil

        // Observe the LockBLE state and drive the next step of the flow.
        observation = Task { [weak self] in
            guard let self else { return }
            for await bleState in await observeBLEState() {
                await self.handle(bleState: bleState)
            }
        }

        ble.scan(scooterCode: scooterCode)
    }

    // ── BLE state → flow step ──────────────────────────────────

    private func handle(bleState: UnlockState) async {
        displayState = bleState

        switch bleState {
        case .fetchingMAC(let nonce):
            await fetchMACAndUnlock(nonce: nonce)
        case .failed(let reason):
            errorMessage = reason
        default:
            break
        }
    }

    private func fetchMACAndUnlock(nonce: String) async {
        guard let handoff else {
            displayState = .failed(reason: "No agent token available")
            return
        }
        do {
            let mac = try await client.unlock(
                bearerToken: handoff.bearerToken,
                reservationId: handoff.reservationId,
                nonce: nonce
            )
            ble.writeUnlock(reservationId: handoff.reservationId, mac: mac)
        } catch {
            displayState = .failed(reason: error.localizedDescription)
            errorMessage = error.localizedDescription
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
                        if case .failed = current  { continuation.finish(); break }
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

    // Supplied by SkootiClipApp via environment / direct initialisation.
    let scooterCode: String
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
            vm.start(scooterCode: scooterCode, handoff: handoff)
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
            Text(scooterCode)
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
        case .idle, .scanning, .connecting, .readingChallenge, .fetchingMAC, .writingUnlock:
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
        case .idle:                    return "Preparing…"
        case .scanning:                return "Looking for scooter…"
        case .connecting:              return "Connecting…"
        case .readingChallenge:        return "Handshaking…"
        case .fetchingMAC:             return "Verifying with server…"
        case .writingUnlock:           return "Unlocking…"
        case .unlocked:                return "Unlocked! Ride safely."
        case .failed(let reason):      return reason
        }
    }

    // ── Retry ─────────────────────────────────────────────────

    private var retryButton: some View {
        Button("Try again") {
            vm.start(scooterCode: scooterCode, handoff: handoff)
        }
        .buttonStyle(.borderedProminent)
    }
}
