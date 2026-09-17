/*
 * jti_store.c — one-shot jti replay-prevention store, RAM-only as shipped.
 *
 * Portable C99.  Compiles on host (clang/gcc) and ESP32-C3 toolchain.
 *
 * See jti_store.h for the full design rationale, bounding argument, and
 * storage backend description.
 *
 * WHAT THIS FILE CONTAINS: an in-RAM table and nothing else.  There is no
 * NVS call anywhere in it — every nvs_* name below is inside a comment, and
 * a lock flashed with these sources forgets every consumed jti the moment it
 * loses power.  The block that follows is the work an adopter must do to
 * change that.
 *
 * =========================================================================
 * NVS WIRING (the adopter's step — NOT compiled, NOT shipped)
 * =========================================================================
 * On the ESP32, replace the in-memory s_table array with NVS persistence:
 *
 *   // NVS: load table from NVS at startup (in setup() or jti_store_init()):
 *   //   nvs_handle_t h;
 *   //   nvs_open("jti_store", NVS_READWRITE, &h);
 *   //   size_t sz = sizeof(s_table);
 *   //   nvs_get_blob(h, "table", s_table, &sz);
 *   //   nvs_close(h);
 *
 *   // NVS: persist table after each insert/prune (end of jti_seen_or_insert):
 *   //   nvs_open("jti_store", NVS_READWRITE, &h);
 *   //   nvs_set_blob(h, "table", s_table, sizeof(s_table));
 *   //   nvs_commit(h);
 *   //   nvs_close(h);
 *
 * The table is a flat array of JTI_STORE_ENTRY structs (POD; fixed-size).
 * SIZE IT WITH sizeof(s_table), NEVER BY HAND: the uint64_t exp forces
 * 8-byte alignment, so the 33-byte jti[] occupies 40 and one entry is 48
 * bytes rather than the 41 its fields add up to.  Measured on this host
 * (clang 17, arm64, -std=c99): sizeof(entry) 48, sizeof(s_table) 3072.
 * Padding is the compiler's and the target's business, so 3072 is a reading
 * and not a constant of the format; what holds everywhere is that 64 entries
 * of a 41-byte payload stay far below the NVS namespace capacity (default
 * 16 KB on ESP32), which the static assertion under the declaration below
 * makes the compiler check rather than the reader.  The nvs_set_blob line
 * above already passes sizeof(s_table), so the blob is whatever this
 * target's compiler actually laid out.
 *
 * ONCE THE CALLS ABOVE ARE WIRED, the table survives reboots/power-cycles:
 * a consumed jti is remembered until its exp passes, even if the board
 * restarts between the first and second unlock attempt.  Until then it does
 * not, and host_test.c test [15] is the run that says so.
 * =========================================================================
 */

#include "jti_store.h"
#include <string.h>
#include <stddef.h>

/* --------------------------------------------------------------------------
 * Internal table entry
 * -------------------------------------------------------------------------- */

typedef struct {
    char     jti[JTI_MAX_LEN]; /* NUL-terminated; empty entry has jti[0] == '\0' */
    uint64_t exp;              /* expiry unix seconds; 0 = free slot              */
} JTI_STORE_ENTRY;

/* In-memory table — zero-initialized (all slots free at startup), and that
 * is the whole of the storage this file has.  A restart of the program, and
 * so a power cycle of the lock, starts from an empty table.
 *
 * NVS: on ESP32, this would be loaded from nvs_get_blob at startup and
 * saved via nvs_set_blob after each mutation.  See the NVS WIRING comment
 * block at the top of this file.
 */
static JTI_STORE_ENTRY s_table[JTI_STORE_SIZE];

/* The sizing sentence in the NVS WIRING block is held by the compiler rather
 * than by a reader's arithmetic: this declaration is ill-formed (negative
 * array size) on any target where the table outgrows the default 16 KB NVS
 * namespace.  C99, so it needs no _Static_assert. */
typedef char jti_store_fits_nvs_namespace[(sizeof(s_table) <= 16384) ? 1 : -1];

/* --------------------------------------------------------------------------
 * jti_store_reset — wipe the table (for tests)
 * -------------------------------------------------------------------------- */

void jti_store_reset(void)
{
    memset(s_table, 0, sizeof(s_table));
}

/* --------------------------------------------------------------------------
 * jti_seen_or_insert
 * -------------------------------------------------------------------------- */

int jti_seen_or_insert(const char *jti, uint64_t exp, uint64_t now)
{
    size_t   jti_len;
    int      i;
    int      found_idx    = -1;  /* index of a matching (same-jti) entry    */
    int      free_idx     = -1;  /* index of a free (exp == 0) slot         */
    int      evict_idx    = -1;  /* fallback: slot with smallest exp value  */
    uint64_t evict_exp    = UINT64_MAX;

    /* --- argument validation --- */
    if (!jti || jti[0] == '\0') return -1;
    jti_len = strnlen(jti, JTI_MAX_LEN);
    if (jti_len >= JTI_MAX_LEN) return -1; /* too long */

    /* --- Step 1: prune expired entries + scan for existing jti --- */
    for (i = 0; i < JTI_STORE_SIZE; i++) {
        if (s_table[i].exp == 0) {
            /* Free slot — remember first one */
            if (free_idx < 0) free_idx = i;
            continue;
        }

        if (s_table[i].exp <= now) {
            /* Expired — prune (marks as free) */
            s_table[i].jti[0] = '\0';
            s_table[i].exp    = 0;
            if (free_idx < 0) free_idx = i;
            continue;
        }

        /* Active entry — check for jti match */
        if (strncmp(s_table[i].jti, jti, JTI_MAX_LEN) == 0) {
            found_idx = i;
            /* Do NOT break: continue pruning expired entries */
        }

        /* Track candidate for eviction (soonest to expire among active) */
        if (s_table[i].exp < evict_exp) {
            evict_exp = s_table[i].exp;
            evict_idx = i;
        }
    }

    /* --- Step 2: if jti already seen and still in window → REJECT --- */
    if (found_idx >= 0 && s_table[found_idx].exp > now) {
        return 1; /* SEEN — replay attack */
    }

    /* --- Step 3: insert into the best available slot ---
     * Preference: free_idx (pruned/empty) > evict_idx (active, soonest exp).
     * This ensures we prefer removing stale data before evicting live entries.
     */
    {
        int slot = (free_idx >= 0) ? free_idx : evict_idx;
        if (slot < 0) {
            /* Should be unreachable: evict_idx is always set when the table
             * is full (at least one active entry exists). */
            return -1;
        }

        memset(s_table[slot].jti, 0, JTI_MAX_LEN);
        memcpy(s_table[slot].jti, jti, jti_len);
        s_table[slot].jti[jti_len] = '\0';
        s_table[slot].exp = exp;

        /* NVS: nvs_set_blob / nvs_commit would go here on the ESP32 board.
         * See the NVS WIRING comment block at the top of this file. */
    }

    return 0; /* NEW — accepted */
}
