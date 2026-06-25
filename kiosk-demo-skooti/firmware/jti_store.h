/*
 * jti_store.h — durable jti (JWT ID) replay-prevention store.
 *
 * Portable C99.  No ESP32/Arduino-specific dependencies in this header.
 * Compiles on host (clang/gcc) and ESP32-C3 toolchain.
 *
 * =========================================================================
 * PURPOSE
 * =========================================================================
 * The rental-token lock must reject a replayed jti within its exp window,
 * even across a reboot (power-cycle) of the ESP32.  The RAM-only circular
 * cache used in the previous firmware was insufficient:
 *   - Cleared on reboot → entire validity window re-openable.
 *   - Fixed 16 entries → eviction replay after ≥ 16 unlocks per window.
 *
 * This module provides a fixed-size table of {jti, exp} entries:
 *   - Entries are retained until their exp passes.
 *   - jti_seen_or_insert() atomically checks + records a jti.
 *   - Expired entries (exp <= now) are pruned on each call, bounding the
 *     table to at most one entry per token in the active 15-min window.
 *
 * =========================================================================
 * STORAGE BACKENDS
 * =========================================================================
 * HOST TEST (in-memory):
 *   A static C array of JTI_STORE_SIZE entries.  Zero-initialized.
 *   Used by host_test.c — no NVS or board required.
 *
 * ESP32 / NVS (production):
 *   The same fixed-size table is persisted via NVS (nvs_set_blob /
 *   nvs_get_blob).  See the "NVS:" comment blocks in jti_store.c showing
 *   exactly where nvs_set_blob / nvs_get_blob wire in.
 *   Use the Preferences library or esp_partition API on the board.
 *
 * =========================================================================
 * BOUNDING ARGUMENT
 * =========================================================================
 * Token TTL = 900 s (15 min).  Each entry is pruned when exp <= now.
 * So the table holds at most one entry per distinct token that was accepted
 * within the last 15 min.  JTI_STORE_SIZE = 64 gives comfortable headroom
 * for a busy lock (≫ 64 unlock/15-min is not a real-world concern for a
 * scooter lock).
 */

#ifndef JTI_STORE_H
#define JTI_STORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Maximum number of jti entries retained at one time. */
#define JTI_STORE_SIZE 64

/* Max jti length (32 hex chars + NUL).  Longer jtis are rejected. */
#define JTI_MAX_LEN 33

/*
 * jti_seen_or_insert — check for replay and record a jti.
 *
 * Algorithm:
 *   1. Prune all entries with exp <= now (expired — no longer replayable).
 *   2. If jti is present with stored exp > now → return 1 (SEEN → REJECT).
 *   3. Else insert {jti, exp}:
 *        - If a free (exp == 0) slot is available, use it.
 *        - Else evict the entry with the smallest exp (soonest to expire,
 *          or already expired if pruning didn't fully drain the table).
 *      Return 0 (NEW → ACCEPT; caller should unlock).
 *
 * Parameters:
 *   jti   : NUL-terminated jti string (must be <= JTI_MAX_LEN - 1 chars).
 *   exp   : expiry Unix timestamp of the token (seconds).
 *   now   : current Unix timestamp (seconds).
 *
 * Returns:
 *   0  — jti not previously seen; entry recorded.  Caller: proceed with unlock.
 *   1  — jti already seen (replay attack).  Caller: REJECT.
 *  -1  — invalid argument (NULL, empty, or jti too long).
 *
 * Thread-safety: NOT thread-safe (single-threaded BLE callback context on ESP32).
 */
int jti_seen_or_insert(const char *jti, uint64_t exp, uint64_t now);

/*
 * jti_store_reset — wipe the entire table (for testing only).
 * Not called from production code.
 */
void jti_store_reset(void);

#ifdef __cplusplus
}
#endif

#endif /* JTI_STORE_H */
