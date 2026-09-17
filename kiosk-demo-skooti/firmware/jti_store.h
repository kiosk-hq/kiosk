/*
 * jti_store.h — one-shot jti (JWT ID) replay-prevention store, RAM-only.
 *
 * Portable C99.  No ESP32/Arduino-specific dependencies in this header.
 * Compiles on host (clang/gcc) and ESP32-C3 toolchain.
 *
 * =========================================================================
 * PURPOSE, AND THE HALF OF IT THIS MODULE DOES NOT DO
 * =========================================================================
 * The rental-token lock must reject a replayed jti within its exp window.
 * Two properties are load-bearing, and a RAM-only or under-sized cache gives
 * away one each: a store cleared on reboot re-opens the whole validity
 * window, and a store small enough to wrap in normal use evicts a jti that is
 * still live.
 *
 * THIS MODULE AS SHIPPED HOLDS THE SECOND AND NOT THE FIRST.  The table is a
 * static C array, empty at every program start, so a power cycle forgets
 * every consumed jti and a token still inside its 15-minute window unlocks a
 * second time.  Closing that is an ADOPTER'S STEP, not something the flashed
 * sketch already does: the NVS WIRING block at the top of jti_store.c is the
 * exact code to add, and nothing here is durable until it is added.
 *
 * This module provides a fixed-size table of {jti, exp} entries:
 *   - Entries are retained, for as long as the process lives, until their
 *     exp passes.
 *   - jti_seen_or_insert() atomically checks + records a jti.
 *   - Expired entries (exp <= now) are pruned on each call, bounding the
 *     table to at most one entry per token in the active 15-min window.
 *
 * =========================================================================
 * STORAGE BACKEND
 * =========================================================================
 * SHIPPED (in-memory, on the host AND on the board):
 *   A static C array of JTI_STORE_SIZE entries.  Zero-initialized at every
 *   start.  Used by host_test.c and by skooti_lock.ino as flashed — no NVS,
 *   no board required, and no durability across a restart.
 *
 * ESP32 / NVS (the adopter adds this; it is NOT in the shipped sources):
 *   The same fixed-size table, persisted with nvs_set_blob / nvs_get_blob.
 *   The "NVS:" comment blocks in jti_store.c show exactly where those calls
 *   wire in; the Preferences library or the esp_partition API does the same
 *   job.  Until they are wired, jti_seen_or_insert forgets on reboot, and
 *   `make test` asserts exactly that — see host_test.c test [15].
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
