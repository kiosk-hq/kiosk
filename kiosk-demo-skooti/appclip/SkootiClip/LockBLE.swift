// LockBLE.swift — CoreBluetooth central manager for the SKOOTI lock (Arch 2)
//
// BLE contract (must match skooti_lock.ino EXACTLY):
//
//   Service UUID:  4e2a1000-5b3c-4b1e-9f8c-6d7e8a9b0c1d
//
//   Unlock UUID:   4e2a1002-5b3c-4b1e-9f8c-6d7e8a9b0c1d
//     Properties:  WRITE (+ WRITE_NR)
//     Format:      wire rental token (UTF-8 string, up to ~220 bytes)
//                  "<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>.<base64url(sig)>"
//
// Cross-checked against:
//   firmware/skooti_lock.ino  #define SERVICE_UUID / UNLOCK_UUID
//   firmware/skooti_lock.ino  UnlockCallbacks::onWrite — receives the full wire token
//
// Arch 2 flow (NO challenge, NO server round-trip):
//   scan → connect → discover unlock characteristic → write rental token → unlocked
//
// The rental token arrives in the launch URL rt= param (already in memory as a String).
// LockBLE receives it via writeToken(rentalToken:) and writes the raw UTF-8 bytes to
// the unlock characteristic.
//
// MTU note: NimBLE on the lock negotiates MTU 256 (NimBLEDevice::setMTU(256)).  A
// typical wire token is ~180-220 bytes.  CoreBluetooth exposes the negotiated limit
// via peripheral.maximumWriteValueLength(for: .withResponse); if the token exceeds
// that limit the write is rejected with "ATT error 0x06" (request not supported for
// large writes).  In practice iOS negotiates ≥ 185 bytes with a nearby BLE 4.2+
// peripheral; if you hit this limit split the write into a Prepared Write procedure
// or reduce scooter_code / reservation_id lengths.
//
// Foreground BLE only: App Clips cannot use background BLE
// (CBCentralManagerOptionRestoreIdentifierKey is unavailable).
// The App Clip must stay in the foreground throughout the unlock flow (~5–10 s).

import CoreBluetooth
import Foundation

// ============================================================
// MARK: — UUIDs (verbatim from skooti_lock.ino)
// ============================================================

private let kServiceUUID = CBUUID(string: "4e2a1000-5b3c-4b1e-9f8c-6d7e8a9b0c1d")
private let kUnlockUUID  = CBUUID(string: "4e2a1002-5b3c-4b1e-9f8c-6d7e8a9b0c1d")

// ============================================================
// MARK: — LockBLE
// ============================================================

/// Manages a single BLE connection to a SKOOTI lock (Arch 2 — offline token).
///
/// Usage:
///   1. Call `scan(scooterCode:)` — the manager scans for the SKOOTI service UUID.
///   2. Observe `state` (a `@Published` property) for `UnlockState` transitions.
///   3. Once `state == .writingToken`, the write has been dispatched.
///      On `.unlocked` the lock has acknowledged the write (CoreBluetooth write-with-
///      response).  On the hardware the GPIO fires for 3 s if the token verified.
///      There is no BLE-level success/fail feedback from the firmware — the lock does
///      not write back a result characteristic.  "Write acknowledged" = "command
///      delivered"; the user should see the LED / hear the relay within ~1 s.
///   4. The caller (UnlockViewModel) calls `writeToken(rentalToken:)` once the clip
///      reaches `.discovered` (characteristics found, ready to write).

@MainActor
final class LockBLE: NSObject, ObservableObject {

    // Current BLE / unlock state, observed by the UI.
    @Published private(set) var state: UnlockState = .idle

    // ── Private BLE objects ───────────────────────────────────
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
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

    /// Begin scanning for a SKOOTI lock advertising the service UUID.
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

    /// Write the rental token to the lock's Unlock characteristic.
    ///
    /// Call this once `state == .discovered`.
    ///
    /// The token is the raw `rt` string from the launch URL:
    ///   "<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>.<base64url(sig)>"
    ///
    /// This is written as UTF-8 bytes — identical to what verify.c and
    /// LockSim#unlock receive.
    func writeToken(rentalToken: String) {
        guard let peripheral = peripheral,
              let unlockChar = unlockChar else {
            state = .failed(reason: "BLE peripheral not connected")
            return
        }

        guard let data = rentalToken.data(using: .utf8) else {
            state = .failed(reason: "Failed to encode rental token as UTF-8")
            return
        }

        // Sanity-check the negotiated MTU so the caller knows if chunking is needed.
        let maxWrite = peripheral.maximumWriteValueLength(for: .withResponse)
        if data.count > maxWrite {
            state = .failed(reason: "Token (\(data.count) bytes) exceeds negotiated MTU " +
                            "(\(maxWrite) bytes). Reduce token length or split the write.")
            return
        }

        state = .writingToken
        // Write with response so CoreBluetooth surfaces any ATT error.
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
            // Stop scanning — connect to the first SKOOTI peripheral found.
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
            state = .discovering
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
            // Discover only the unlock characteristic — no challenge in Arch 2.
            peripheral.discoverCharacteristics([kUnlockUUID], for: service)
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
                if char.uuid == kUnlockUUID { unlockChar = char }
            }
            guard unlockChar != nil else {
                state = .failed(reason: "Unlock characteristic not found on peripheral")
                return
            }
            // Ready — ViewModel will call writeToken(rentalToken:).
            state = .discovered
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
                    state = .failed(reason: "Token write failed: \(error.localizedDescription)")
                    return
                }
                // CoreBluetooth confirms the write was accepted by the lock.
                // On hardware the GPIO fires for 3 s if the token verified correctly.
                // The firmware does not send a result characteristic back — treat a
                // successful ATT write as "command delivered".
                state = .unlocked
            }
        }
    }
}
