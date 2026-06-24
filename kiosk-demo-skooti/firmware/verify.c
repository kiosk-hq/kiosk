/*
 * verify.c — skooti unlock verification (portable C99)
 *
 * No BLE, Arduino, or platform-specific dependencies.
 * Compiles on host (clang/gcc) and ESP32-C3 toolchain.
 *
 * See verify.h for message layout documentation.
 */

#include "verify.h"
#include <string.h>
#include <stdint.h>

/* --------------------------------------------------------------------------
 * hex helpers (internal, no printf dependency on embedded target)
 * -------------------------------------------------------------------------- */

/* Convert a single nibble (0-15) to a lowercase hex character */
static char nibble_to_hex(uint8_t n)
{
    return (char)(n < 10 ? '0' + n : 'a' + n - 10);
}

/*
 * bin_to_hex — encode `len` bytes into `dst` as lowercase hex.
 * dst must be at least 2*len+1 bytes; NUL-terminates.
 */
static void bin_to_hex(const uint8_t *src, size_t len, char *dst)
{
    size_t i;
    for (i = 0; i < len; i++) {
        dst[2*i]   = nibble_to_hex((src[i] >> 4) & 0x0F);
        dst[2*i+1] = nibble_to_hex( src[i]        & 0x0F);
    }
    dst[2*len] = '\0';
}

/* --------------------------------------------------------------------------
 * constant-time comparison (timing-safe, no early exit)
 * -------------------------------------------------------------------------- */

/*
 * ct_memeq — compare `len` bytes of a and b in constant time.
 * Returns 1 if identical, 0 otherwise.
 */
static int ct_memeq(const void *a, const void *b, size_t len)
{
    const uint8_t *pa = (const uint8_t *)a;
    const uint8_t *pb = (const uint8_t *)b;
    uint8_t diff = 0;
    size_t i;
    for (i = 0; i < len; i++)
        diff |= pa[i] ^ pb[i];
    return diff == 0 ? 1 : 0;
}

/* --------------------------------------------------------------------------
 * skooti_verify_unlock
 * -------------------------------------------------------------------------- */

int skooti_verify_unlock(const uint8_t k_lock[32],
                         const char   *scooter_code,
                         const char   *nonce_hex,
                         const char   *reservation_id,
                         const char   *mac_hex)
{
    /*
     * Message layout:
     *   scooter_code + "|" + nonce_hex + "|" + reservation_id
     *
     * Maximum supported total message length: 512 bytes.
     * (scooter codes ≤ 64, nonce_hex = 32, reservation_id ≤ 128 in practice)
     */
    uint8_t computed[32];
    char    computed_hex[65]; /* 64 hex chars + NUL */
    char    msg[512];
    size_t  code_len, nonce_len, resv_len, total;

    if (!k_lock || !scooter_code || !nonce_hex || !reservation_id || !mac_hex)
        return 0;

    /* mac_hex must be exactly 64 chars */
    if (strlen(mac_hex) != 64)
        return 0;

    code_len  = strlen(scooter_code);
    nonce_len = strlen(nonce_hex);
    resv_len  = strlen(reservation_id);

    /* "code|nonce|resv" — two '|' separators */
    total = code_len + 1 + nonce_len + 1 + resv_len;
    if (total >= sizeof(msg))
        return 0; /* message too long — safety guard */

    /* Build message in one block (no dynamic allocation) */
    memcpy(msg,                                   scooter_code,   code_len);
    msg[code_len] = '|';
    memcpy(msg + code_len + 1,                    nonce_hex,      nonce_len);
    msg[code_len + 1 + nonce_len] = '|';
    memcpy(msg + code_len + 1 + nonce_len + 1,    reservation_id, resv_len);
    /* No NUL needed — we pass exact length to hmac_sha256 */

    /* Compute HMAC-SHA256(k_lock, message) */
    hmac_sha256(k_lock, 32, (const uint8_t *)msg, total, computed);

    /* Encode result as lowercase hex */
    bin_to_hex(computed, 32, computed_hex);

    /* Constant-time compare against the provided MAC (exactly 64 bytes) */
    return ct_memeq(computed_hex, mac_hex, 64);
}
