// LockBLE.swift — CoreBluetooth central manager for the SKOOTI lock
//
// BLE contract (must match skooti_lock.ino EXACTLY):
//
//   Service UUID:   4e2a1000-5b3c-4b1e-9f8c-6d7e8a9b0c1d
//   Challenge UUID: 4e2a1001-5b3c-4b1e-9f8c-6d7e8a9b0c1d
//     Properties:   READ + NOTIFY
//     Format:       32 ASCII lowercase hex chars (one-shot nonce)
//
//   Unlock UUID:    4e2a1002-5b3c-4b1e-9f8c-6d7e8a9b0c1d
//     Properties:   WRITE (+ WRITE_NR)
//     Format:       "<reservation_id>|<64-char-mac-hex>"  (ASCII pipe-delimited)
//
// Cross-checked against:
//   firmware/skooti_lock.ino  lines 137-139  (#define SERVICE_UUID / CHALLENGE_UUID / UNLOCK_UUID)
//   firmware/README.md        BLE service / characteristics table
//
// The write format "<reservation_id>|<mac_hex>" is cross-checked against:
//   firmware/skooti_lock.ino  lines 186-188 (UnlockCallbacks::onWrite — pipe split)
//
// Foreground BLE only: App Clips cannot use background BLE (CBCentralManagerOptionRestoreIdentifierKey
// is unavailable).  The App Clip must stay in the foreground throughout the unlock
// flow (~5–10 s).  Validate on-device: check the iOS BLE policy for Clips.

import CoreBluetooth
import Combine
import Foundation

// ============================================================
// MARK: — UUIDs (verbatim from skooti_lock.ino)
// ============================================================

private let kServiceUUID   = CBUUID(string: "4e2a1000-5b3c-4b1e-9f8c-6d7e8a9b0c1d")
private let kChallengeUUID = CBUUID(string: "4e2a1001-5b3c-4b1e-9f8c-6d7e8a9b0c1d")
private let kUnlockUUID    = CBUUID(string: "4e2a1002-5b3c-4b1e-9f8c-6d7e8a9b0c1d")

// ============================================================
// MARK: — LockBLE
// ============================================================

/// Manages a single BLE connection to a SKOOTI lock.
///
/// Usage:
///   1. Call `scan(scooterCode:)` — the manager scans for the SKOOTI service.
///   2. Observe `statePublisher` for UnlockState transitions.
///   3. On `.readingChallenge` → `.fetchingMAC(nonce:)`, the caller
///      fetches the MAC from KioskClient and calls `writeUnlock(…)`.
///   4. On `.writingUnlock` → `.unlocked` the GPIO fires (on the board).
///
/// The caller (UnlockViewModel) drives the overall flow; LockBLE only
/// handles BLE mechanics.

@MainActor
final class LockBLE: NSObject, ObservableObject {

    // Current BLE / unlock state, observed by the UI.
    @Published private(set) var state: UnlockState = .idle
    @Published private(set) var nonce: String?       // set after challenge read

    // ── Private BLE objects ───────────────────────────────────
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var challengeChar: CBCharacteristic?
    private var unlockChar: CBCharacteristic?
    private var pendingScooterCode: String?

    override init() {
        super.init()
        // Initialise on the main queue; App Clips are foreground-only.
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // ────────────────────────────────────────────────────────────
    // MARK: — Public API
    // ────────────────────────────────────────────────────────────

    /// Begin scanning for a SKOOTI lock advertising service UUID.
    /// The scooterCode is used for logging / future device-name filtering.
    func scan(scooterCode: String) {
        guard state == .idle else { return }
        pendingScooterCode = scooterCode
        state = .scanning

        if central.state == .poweredOn {
            startScanning()
        }
        // else: wait for centralManagerDidUpdateState callback
    }

    /// Write the unlock payload to the lock's Unlock characteristic.
    ///
    /// Call this after receiving the MAC from KioskClient.unlock(…).
    ///
    /// Format (verbatim from firmware/skooti_lock.ino UnlockCallbacks::onWrite):
    ///   "<reservation_id>|<64-char-mac-hex>"  (ASCII, pipe-delimited)
    func writeUnlock(reservationId: String, mac: String) {
        guard let peripheral = peripheral,
              let unlockChar = unlockChar else {
            state = .failed(reason: "BLE peripheral not connected")
            return
        }

        // Build the exact byte string the firmware expects.
        let payload = "\(reservationId)|\(mac)"
        guard let data = payload.data(using: .utf8) else {
            state = .failed(reason: "Failed to encode unlock payload as UTF-8")
            return
        }

        state = .writingUnlock
        // Use withResponse so CoreBluetooth surfaces any write error.
        peripheral.writeValue(data, for: unlockChar, type: .withResponse)
    }

    // ────────────────────────────────────────────────────────────
    // MARK: — Private helpers
    // ────────────────────────────────────────────────────────────

    private func startScanning() {
        central.scanForPeripherals(
            withServices: [kServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
}

// ============================================================
// MARK: — CBCentralManagerDelegate
// ============================================================

extension LockBLE: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if state == .scanning {
                    startScanning()
                }
            case .poweredOff:
                state = .failed(reason: "Bluetooth is powered off. Please enable Bluetooth.")
            case .unauthorized:
                state = .failed(reason: "Bluetooth permission denied. Allow Bluetooth in Settings.")
            case .unsupported:
                state = .failed(reason: "This device does not support Bluetooth LE.")
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            // Stop scanning — we connect to the first SKOOTI peripheral found.
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            state = .connecting
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        Task { @MainActor in
            state = .readingChallenge
            peripheral.discoverServices([kServiceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            state = .failed(reason: error?.localizedDescription ?? "Failed to connect")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            if case .unlocked = state { return } // normal post-unlock disconnect
            if let error = error {
                state = .failed(reason: "Disconnected: \(error.localizedDescription)")
            }
        }
    }
}

// ============================================================
// MARK: — CBPeripheralDelegate
// ============================================================

extension LockBLE: CBPeripheralDelegate {

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        Task { @MainActor in
            if let error = error {
                state = .failed(reason: "Service discovery failed: \(error.localizedDescription)")
                return
            }
            guard let service = peripheral.services?.first(where: { $0.uuid == kServiceUUID }) else {
                state = .failed(reason: "SKOOTI service not found on peripheral")
                return
            }
            peripheral.discoverCharacteristics([kChallengeUUID, kUnlockUUID], for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let error = error {
                state = .failed(reason: "Characteristic discovery failed: \(error.localizedDescription)")
                return
            }
            for char in service.characteristics ?? [] {
                if char.uuid == kChallengeUUID { challengeChar = char }
                if char.uuid == kUnlockUUID    { unlockChar = char }
            }
            guard challengeChar != nil, unlockChar != nil else {
                state = .failed(reason: "Required characteristics not found")
                return
            }
            // READ the challenge characteristic → lock generates a fresh nonce.
            peripheral.readValue(for: challengeChar!)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if characteristic.uuid == kChallengeUUID {
                if let error = error {
                    state = .failed(reason: "Challenge read failed: \(error.localizedDescription)")
                    return
                }
                guard let data = characteristic.value,
                      let hex = String(data: data, encoding: .utf8),
                      hex.count == 32,
                      hex.allSatisfy({ $0.isHexDigit }) else {
                    state = .failed(reason: "Invalid nonce from lock (expected 32 hex chars)")
                    return
                }
                nonce = hex
                // Transition to fetchingMAC — the ViewModel picks this up
                // and calls KioskClient.unlock(…) then writeUnlock(…).
                state = .fetchingMAC(nonce: hex)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if characteristic.uuid == kUnlockUUID {
                if let error = error {
                    state = .failed(reason: "Unlock write failed: \(error.localizedDescription)")
                    return
                }
                // CoreBluetooth confirms the write was accepted.  On the lock
                // side the GPIO fires for 3 s if the MAC verified correctly.
                // There is no BLE-level success/fail response from the firmware
                // (the lock just drives GPIO); treat a successful write as
                // "command delivered".
                state = .unlocked
            }
        }
    }
}
