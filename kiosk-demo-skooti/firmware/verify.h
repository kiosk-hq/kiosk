/*
 * verify.h — skooti BLE lock unlock verification
 *
 * Shared between:
 *   - skooti_lock.ino  (ESP32-C3 Arduino firmware)
 *   - host_test.c      (host-side crypto proof)
 *
 * No BLE, Arduino, or platform-specific dependencies.
 * Requires only hmac_sha256.h + C standard library.
 *
 * Message layout (CRITICAL — DO NOT CHANGE without updating all sites):
 *
 *   message = scooter_code (UTF-8)
 *             + "|"
 *             + nonce_hex  (32 lowercase hex chars = 16 raw bytes)
 *             + "|"
 *             + reservation_id (UTF-8)
 *
 * Example:  "SK-001|00112233445566778899aabbccddeeff|resv-1"
 *
 * This EXACTLY mirrors:
 *   Ruby (server):     UnlockAuthority.mac  in kiosk-server/unlock_authority.rb
 *   Ruby (simulator):  LockSim#unlock       in kiosk-demo-skooti/lib/lock_sim.rb
 *   C (firmware):      skooti_lock.ino      (calls skooti_verify_unlock)
 *   C (host test):     host_test.c          (calls skooti_verify_unlock)
 */
#ifndef VERIFY_H
#define VERIFY_H

#include <stdint.h>
#include "hmac_sha256.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * skooti_verify_unlock — verify a server-issued HMAC unlock MAC.
 *
 * Parameters:
 *   k_lock        : 32 raw bytes = HMAC-SHA256(master_key, scooter_code)
 *                   (provisioned into the lock at manufacture; NEVER the master key)
 *   scooter_code  : NUL-terminated UTF-8 string (e.g. "SK-001")
 *   nonce_hex     : 32 lowercase hex chars (16 bytes), the one-shot challenge
 *                   previously issued by this lock
 *   reservation_id: NUL-terminated UTF-8 string (e.g. "resv-1")
 *   mac_hex       : 64 lowercase hex chars — the MAC received from the server
 *                   via the App Clip / agent
 *
 * Returns:
 *   1  — MAC is valid; caller should unlock (GPIO high) and consume the nonce
 *   0  — MAC is invalid or parameters are out of range; stay locked
 *
 * Security properties:
 *   - The comparison is CONSTANT-TIME (timing-safe, no early exit on mismatch).
 *   - mac_hex must be exactly 64 lowercase hex chars; any other length → 0.
 *   - The built message is limited to 512 bytes total (far exceeds any real input).
 */
int skooti_verify_unlock(const uint8_t k_lock[32],
                         const char   *scooter_code,
                         const char   *nonce_hex,
                         const char   *reservation_id,
                         const char   *mac_hex);

#ifdef __cplusplus
}
#endif

#endif /* VERIFY_H */
