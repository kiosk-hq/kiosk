/*
 * jti_store.c — durable jti replay-prevention store.
 *
 * Portable C99.  Compiles on host (clang/gcc) and ESP32-C3 toolchain.
 *
 * See jti_store.h for the full design rationale, bounding argument, and
 * storage backend description.
 *
 * =========================================================================
 * NVS WIRING (ESP32 production)
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
 * sizeof(s_table) = 64 * (33 + 8) = 2624 bytes — well within the NVS
 * namespace capacity (default 16 KB on ESP32).
 *
 * With NVS persistence, the table survives reboots/power-cycles:
 * a consumed jti is remembered until its exp passes, even if the board
 * restarts between the first and second unlock attempt.
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

/* In-memory table — zero-initialized (all slots free at startup).
 *
 * NVS: on ESP32, this would be loaded from nvs_get_blob at startup and
 * saved via nvs_set_blob after each mutation.  See the NVS WIRING comment
 * block at the top of this file.
 */
static JTI_STORE_ENTRY s_table[JTI_STORE_SIZE];

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
