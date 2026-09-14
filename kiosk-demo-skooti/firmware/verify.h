/*
 * verify.h — skooti BLE lock offline rental-token verification (offline Ed25519)
 *
 * Shared between:
 *   - skooti_lock.ino  (ESP32-C3 Arduino firmware)
 *   - host_test.c      (host-side crypto proof, no board required)
 *
 * No BLE, Arduino, or platform-specific dependencies.
 * Requires only ed25519/ (vendored orlp/ed25519) + C standard library.
 *
 * =========================================================================
 * TOKEN WIRE FORMAT (offline Ed25519, domain-separated)
 * =========================================================================
 *
 *   wire token = "<message>.<base64url(sig)>"
 *
 *   message    = "kiosk-rental-v1|<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>"
 *                (EXACTLY 6 pipe-delimited fields — a message with any other
 *                 count is refused, whatever its signature — and every field
 *                 non-empty)
 *
 *   Field indices (0-based), with the charset each one is held to:
 *     [0] "kiosk-rental-v1"  — domain-separation tag (REQUIRED; checked first)
 *     [1] scooter_code       — e.g. "SK-001"; 1+ chars of A-Za-z0-9-._~ AND
 *                              must equal this lock's own provisioned code
 *     [2] reservation_id     — e.g. "resv-1"; 1+ chars of A-Za-z0-9-._~,
 *                              not interpreted further by this lock
 *     [3] iat                — 1-20 ASCII digits, issued-at unix seconds
 *     [4] exp                — 1-20 ASCII digits, expiry unix seconds (iat + 900)
 *     [5] jti                — 32 lowercase hex chars (anti-replay token ID)
 *
 *   A-Za-z0-9-._~ is the RFC 3986 unreserved set. Fields 1 and 2 are the two
 *   this lock does not otherwise interpret, and holding them to a set of 66
 *   characters rather than to "any bytes but the delimiter" is what makes the
 *   grammar's claim about them CHECKABLE: the shared vector set carries a
 *   vector for every one of the 256 byte values, where an unenumerable domain
 *   could only ever be sampled. Every byte of a well-formed message is
 *   therefore '|' or one of those 66.
 *
 *   sig        = Ed25519 signature over the message bytes (64 bytes)
 *                base64url-encoded, NO padding characters
 *
 *   Split: find the LAST '.' in the wire token — everything to the left is
 *   the message (signed verbatim), everything to the right is the sig.
 *
 *   THE CANONICAL STATEMENT OF THIS GRAMMAR IS ../RENTAL_TOKEN.md, and two
 *   Ruby readers implement it beside this one: RentalTokenIssuer.verify
 *   (server-side) and script/lock_sim.rb (the software lock). `make crosscheck`
 *   runs one shared vector set — firmware/token_vectors.rb — through all three
 *   and fails when any of them answers a vector differently from the other two
 *   or from the answer the set declares.
 *
 * Example (known-answer vector):
 *   message = "kiosk-rental-v1|SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899"
 *   sig     = "SDKHoyU3zzqvpVCwOcKf75EMJCyNKaxuRbvY3HmuM-q--ZaMEdeSmBi40JgZyhvBuL4A15xlupYqlGMfCnROCg"
 *
 * =========================================================================
 * DOMAIN SEPARATION
 * =========================================================================
 * The leading "kiosk-rental-v1" tag ensures this signing key cannot be
 * cross-used to mint any token a lock would honor for a different purpose.
 * The lock rejects field[0] != "kiosk-rental-v1" before any other claim.
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
 * jti durable-replay check is performed by the CALLER (lock firmware or
 * lock-sim) via jti_store.h:
 *   jti_seen_or_insert(jti, exp, now)
 * skooti_verify_token() verifies the signature and checks the claims but does
 * NOT maintain the consumed-jti set — that belongs in the caller's jti_store
 * (NVS-backed on the board; in-memory table for host tests).
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
 *   - The signature's SCALAR is range-checked HERE, before that call. RFC 8032
 *     5.1.7 decodes the second 32 bytes as a number below the group order L;
 *     the vendored verifier bounds them only by `signature[63] & 224`, which
 *     admits S and S + L alike, and [L]B is the identity so both satisfy one
 *     equation. OpenSSL applies the range check, so without this the physical
 *     lock — the widest reader — would take a second spelling of a token both
 *     Ruby readers refuse. The comparison is constant-time: 32 fixed
 *     iterations, no branch on the bytes, no load indexed by them.
 *   - Scooter-code comparison is constant-time (ct_memeq).
 *   - All field accesses are bounds-checked; no OOB on a malformed token.
 *   - The field COUNT is a gate, not an assumption: fewer than six fields and
 *     more than six are both refused, so the claim read as `exp` is always the
 *     fifth field of a six-field message and never something a shifted field
 *     put there. This is the same answer the server's own Ruby verifier gives.
 *   - So is every field's CHARSET. An empty field, a `scooter_code` or
 *     `reservation_id` outside A-Za-z0-9-._~, an `iat` or `exp` that is not
 *     1-20 plain digits, and a `jti` that is not 32 lowercase hex are each
 *     refused. This is narrower than a permissive integer parse deliberately:
 *     the three readers of this token must refuse the same bytes, and the
 *     widest reader is the one that decides what an adopter's fleet accepts.
 *   - b64url_decode takes a dst_cap argument and hard-stops at the buffer
 *     boundary; an oversized sig field is rejected before any stack write.
 *     An early sig_b64_len > 88 guard rejects implausibly long sig fields
 *     before decoding (64 decoded bytes → 86 base64url chars, ±2 slack).
 *
 * After a return of 1 the caller can retrieve the jti for anti-replay by
 * re-parsing token (split on last '.', split message on '|', field[5] of
 * exactly six, 32 lowercase hex).
 * For convenience skooti_parse_jti() is provided below.
 */
int skooti_verify_token(const uint8_t pubkey[32],
                        const char   *token,
                        const char   *my_scooter_code,
                        uint64_t      now_unix);

/*
 * skooti_verify_wire — verify a rental token whose LENGTH the caller knows.
 *
 * This is the entry point for anything that receives the token as a byte
 * buffer — a BLE write, a file, a socket — and it is what skooti_lock.ino
 * calls with the write's own size.
 *
 * WHY IT EXISTS. skooti_verify_token takes a `const char *` and therefore ends
 * at the first NUL, whatever the caller was handed. A BLE write carrying a NUL
 * would be verified as the PREFIX before it, and the bytes after it — which
 * the writer chose and the signature does not cover — would never be looked
 * at. The wire token holds no NUL (../RENTAL_TOKEN.md states this once, for
 * all three readers of the token), so a buffer that contains one is refused
 * here rather than truncated and verified.
 *
 * WHAT token_len MEANS, because a length argument a function ignores is worse
 * than no length argument at all. It is the number of bytes the caller
 * received, NOT counting any terminator the caller appended, and it BOUNDS the
 * whole verification: no byte at or past token + token_len is read, by this
 * function or by anything it calls. So the buffer needs NO terminator — a
 * socket read, a ring buffer or a BLE reassembly can be handed straight in —
 * and a caller that declares a length shorter than the terminated content gets
 * the SHORTER token verified, never the longer one it did not declare.
 *
 * Parameters are skooti_verify_token's, plus token_len.
 *
 * Returns 1 on the same conditions skooti_verify_token returns 1 for the first
 * token_len bytes, and 0 when the buffer is empty, longer than
 * SKOOTI_TOKEN_MAX, or holds a NUL byte within token_len.
 */
int skooti_verify_wire(const uint8_t pubkey[32],
                       const char   *token,
                       size_t        token_len,
                       const char   *my_scooter_code,
                       uint64_t      now_unix);

/*
 * skooti_parse_jti — extract the jti field from a verified wire token.
 *
 * Call only AFTER skooti_verify_token() returns 1.
 * Copies the jti into jti_out (caller-supplied buffer of at least jti_out_sz
 * bytes, NUL-terminated). It applies the same field-count and jti-charset
 * gates skooti_verify_token applies, so the replay store is never keyed on
 * bytes that verifier would have refused.
 *
 * Returns 1 on success, 0 on parse error.
 */
int skooti_parse_jti(const char *token, char *jti_out, size_t jti_out_sz);

/*
 * skooti_parse_jti_n — skooti_parse_jti for a caller that knows the LENGTH.
 *
 * The pair to skooti_verify_wire, and it exists for the same reason: a caller
 * that verified within its own byte count and then took the replay key through
 * the NUL-terminated entry point would hand that bound straight back, because
 * the key would be read with a walk the verify had refused to make. token_len
 * bounds this parse exactly as it bounds that one — no byte at or past
 * token + token_len is read — so a buffer with no terminator is safe here too.
 *
 * Call only AFTER skooti_verify_wire() returns 1, with the SAME token_len.
 *
 * Returns 1 on success, 0 on parse error, on an empty or over-cap buffer, or
 * when a NUL falls within token_len.
 */
int skooti_parse_jti_n(const char *token, size_t token_len,
                       char *jti_out, size_t jti_out_sz);

#ifdef __cplusplus
}
#endif

#endif /* VERIFY_H */
