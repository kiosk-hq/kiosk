/*
 * verify.h — skooti BLE lock offline rental-token verification (Arch 2)
 *
 * Shared between:
 *   - skooti_lock.ino  (ESP32-C3 Arduino firmware)
 *   - host_test.c      (host-side crypto proof, no board required)
 *
 * No BLE, Arduino, or platform-specific dependencies.
 * Requires only ed25519/ (vendored orlp/ed25519) + C standard library.
 *
 * =========================================================================
 * TOKEN WIRE FORMAT (Arch 2 — offline Ed25519)
 * =========================================================================
 *
 *   wire token = "<message>.<base64url(sig)>"
 *
 *   message    = "<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>"
 *                (UTF-8; iat/exp = unix seconds decimal; jti = 32 hex chars)
 *
 *   sig        = Ed25519 signature over the message bytes (64 bytes)
 *                base64url-encoded, NO padding characters
 *
 *   Split: find the LAST '.' in the wire token — everything to the left is
 *   the message (signed verbatim), everything to the right is the sig.
 *
 * Example:
 *   message = "SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899"
 *   sig     = "b-8ZCqcN1FZAXn4YbXPJXasTED2rwq0DSOXrcRSjI9ajReEBb9Y3m3YSHgNJEElCHSwnEGGYbNGiEWRCZD_yBw"
 *
 * =========================================================================
 * CLOCK REQUIREMENT
 * =========================================================================
 * The lock checks exp > now_unix.  In the demo, now_unix is injected by the
 * caller (DEMO_NOW macro in the .ino / test argument in host_test.c).
 * On a production scooter use a DS3231 RTC or ESP32 time synced when online.
 *
 * =========================================================================
 * ANTI-REPLAY
 * =========================================================================
 * jti one-shot check is performed by the CALLER (lock firmware or lock-sim):
 * skooti_verify_token() verifies the signature and checks the claims but does
 * NOT maintain the consumed-jti set — that belongs in the caller's NVS/RAM.
 */

#ifndef VERIFY_H
#define VERIFY_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Maximum wire-token length accepted (covers ~220-byte real tokens). */
#define SKOOTI_TOKEN_MAX 512

/*
 * skooti_verify_token — verify a skooti-issued Ed25519 rental token.
 *
 * Parameters:
 *   pubkey         : 32 raw bytes — the skooti Ed25519 public key baked into
 *                    this lock at provisioning (one key for all locks).
 *   token          : NUL-terminated wire token: "<message>.<base64url(sig)>"
 *                    Length must be <= SKOOTI_TOKEN_MAX; any longer → 0.
 *   my_scooter_code: NUL-terminated string — this lock's own code (e.g. "SK-001").
 *   now_unix       : current Unix timestamp in seconds (injected — see CLOCK
 *                    REQUIREMENT above).
 *
 * Returns:
 *   1  — signature valid AND scooter_code matches AND exp > now_unix.
 *         Caller must still check jti one-shot before acting on unlock.
 *   0  — any check failed, or token is malformed / too long.
 *
 * Security properties:
 *   - The Ed25519 verify (orlp/ed25519) is internally constant-time.
 *   - Scooter-code comparison is constant-time (ct_memeq).
 *   - All field accesses are bounds-checked; no OOB on a malformed token.
 *   - b64url_decode takes a dst_cap argument and hard-stops at the buffer
 *     boundary; an oversized sig field is rejected before any stack write.
 *     An early sig_b64_len > 88 guard rejects implausibly long sig fields
 *     before decoding (64 decoded bytes → 86 base64url chars, ±2 slack).
 *
 * After a return of 1 the caller can retrieve the jti for anti-replay by
 * re-parsing token (split on last '.', split message on '|', field[4]).
 * For convenience skooti_parse_jti() is provided below.
 */
int skooti_verify_token(const uint8_t pubkey[32],
                        const char   *token,
                        const char   *my_scooter_code,
                        uint64_t      now_unix);

/*
 * skooti_parse_jti — extract the jti field from a verified wire token.
 *
 * Call only AFTER skooti_verify_token() returns 1.
 * Copies the jti into jti_out (caller-supplied buffer of at least jti_out_sz
 * bytes, NUL-terminated).
 *
 * Returns 1 on success, 0 on parse error.
 */
int skooti_parse_jti(const char *token, char *jti_out, size_t jti_out_sz);

#ifdef __cplusplus
}
#endif

#endif /* VERIFY_H */
