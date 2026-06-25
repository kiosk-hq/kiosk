/*
 * verify.c — skooti offline rental-token verification (Arch 2, Ed25519)
 *
 * Portable C99.  No BLE, Arduino, or platform-specific dependencies.
 * Compiles on host (clang/gcc) and ESP32-C3 toolchain.
 *
 * See verify.h for the full token wire-format and clock documentation.
 *
 * Depends on: ed25519/ (vendored orlp/ed25519, zlib license)
 */

#include "verify.h"
#include "ed25519/ed25519.h"

#include <string.h>
#include <stdint.h>
#include <stddef.h>

/* --------------------------------------------------------------------------
 * Constant-time comparison (timing-safe, no early exit)
 * -------------------------------------------------------------------------- */

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
 * Minimal base64url decoder (no padding, RFC 4648 §5 alphabet)
 * -------------------------------------------------------------------------- */

/*
 * b64url_char_to_val — decode one base64url character.
 * Returns 0-63 on success, -1 on invalid character.
 */
static int b64url_char_to_val(unsigned char c)
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '-')              return 62;
    if (c == '_')              return 63;
    return -1; /* invalid */
}

/*
 * b64url_decode — decode a base64url string (no padding) into dst.
 *
 * Parameters:
 *   src     : input base64url string (NOT NUL-terminated necessarily)
 *   src_len : number of input characters
 *   dst     : output buffer
 *   dst_cap : capacity of dst in bytes — writes are bounded to [0, dst_cap)
 *   dst_len : on success, set to the number of decoded bytes
 *
 * Returns 1 on success, 0 if any character is invalid or output would exceed
 * dst_cap (overflow guard — rejects oversized input).
 */
static int b64url_decode(const char *src, size_t src_len,
                         uint8_t *dst, size_t dst_cap, size_t *dst_len)
{
    size_t i;
    size_t out = 0;
    uint32_t accum = 0;
    int      bits  = 0;

    for (i = 0; i < src_len; i++) {
        int val = b64url_char_to_val((unsigned char)src[i]);
        if (val < 0) return 0; /* invalid character */

        accum = (accum << 6) | (uint32_t)val;
        bits += 6;

        if (bits >= 8) {
            bits -= 8;
            if (out >= dst_cap) return 0; /* overflow guard — reject oversized */
            dst[out++] = (uint8_t)((accum >> bits) & 0xFF);
        }
    }

    *dst_len = out;
    return 1;
}

/* --------------------------------------------------------------------------
 * Safe uint64 parse — parse a decimal string to uint64_t
 * Returns 1 on success (non-empty, all digits, no overflow), 0 otherwise.
 * -------------------------------------------------------------------------- */

static int parse_uint64(const char *s, size_t len, uint64_t *out)
{
    uint64_t v = 0;
    size_t i;

    if (len == 0 || len > 20) return 0; /* empty or too long for uint64 */

    for (i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c < '0' || c > '9') return 0;
        /* overflow check: v * 10 + digit > UINT64_MAX */
        if (v > (UINT64_MAX - (uint64_t)(c - '0')) / 10) return 0;
        v = v * 10 + (uint64_t)(c - '0');
    }

    *out = v;
    return 1;
}

/* --------------------------------------------------------------------------
 * skooti_verify_token
 * -------------------------------------------------------------------------- */

int skooti_verify_token(const uint8_t pubkey[32],
                        const char   *token,
                        const char   *my_scooter_code,
                        uint64_t      now_unix)
{
    size_t  token_len;
    size_t  dot_pos;
    size_t  msg_len;
    const char *sig_b64;
    size_t  sig_b64_len;

    /* Decoded sig buffer — Ed25519 sig is exactly 64 bytes */
    uint8_t sig[64];
    size_t  sig_len = 0;

    /* Message field parsing */
    const char *msg;
    /* Fields: scooter_code, reservation_id, iat, exp, jti */
    const char *field_start[5];
    size_t      field_len[5];
    size_t      f;
    const char *p;
    size_t      remaining;
    int         field_idx;

    uint64_t exp_val;
    size_t   code_len;

    /* --- null guards --- */
    if (!pubkey || !token || !my_scooter_code) return 0;

    /* --- token length cap --- */
    token_len = strnlen(token, SKOOTI_TOKEN_MAX + 1);
    if (token_len == 0 || token_len > SKOOTI_TOKEN_MAX) return 0;

    /* --- find the LAST '.' to split message from sig --- */
    dot_pos = token_len; /* sentinel: no dot found */
    {
        size_t i;
        for (i = 0; i < token_len; i++) {
            if (token[i] == '.') dot_pos = i;
        }
    }
    if (dot_pos == token_len) return 0; /* no dot → malformed */

    msg        = token;
    msg_len    = dot_pos;
    sig_b64    = token + dot_pos + 1;
    sig_b64_len = token_len - dot_pos - 1;

    if (msg_len == 0 || sig_b64_len == 0) return 0;

    /* --- early length guard: 64 bytes → 86 base64url chars (no padding).
     * Allow a tiny slack to 88 for robustness; anything longer can only
     * decode to > 64 bytes — reject before touching the stack buffer. --- */
    if (sig_b64_len > 88) return 0;

    /* --- base64url-decode the sig (must be exactly 64 bytes).
     * Pass sizeof(sig) == 64 so the decoder hard-stops at the buffer edge.
     * The sig_len != 64 post-check is kept as defense-in-depth. --- */
    if (!b64url_decode(sig_b64, sig_b64_len, sig, sizeof(sig), &sig_len)) return 0;
    if (sig_len != 64) return 0;

    /* --- Ed25519 verify: sig over msg bytes with pubkey --- */
    if (!ed25519_verify(sig, (const unsigned char *)msg, msg_len,
                        (const unsigned char *)pubkey))
        return 0;

    /* --- Parse the 5 pipe-delimited fields of the message ---
     * Fields: [0]=scooter_code [1]=reservation_id [2]=iat [3]=exp [4]=jti
     * We do NOT need iat or reservation_id for the lock checks, but we must
     * validate that the message has exactly 5 fields and that exp/jti parse.
     */
    field_idx = 0;
    p         = msg;
    remaining = msg_len;

    for (f = 0; f < 5; f++) {
        const char *pipe;
        size_t      flen;

        if (f < 4) {
            /* Find the next '|' */
            size_t j;
            pipe = NULL;
            for (j = 0; j < remaining; j++) {
                if (p[j] == '|') { pipe = p + j; break; }
            }
            if (!pipe) return 0; /* fewer than 5 fields */
            flen = (size_t)(pipe - p);
        } else {
            /* Last field: everything remaining */
            flen = remaining;
        }

        if (flen == 0) return 0; /* empty field */

        field_start[field_idx] = p;
        field_len[field_idx]   = flen;
        field_idx++;

        if (f < 4) {
            p         = pipe + 1;
            remaining = msg_len - (size_t)(p - msg);
        }
    }
    (void)field_idx; /* suppress unused-variable warning */

    /* --- Gate 1: scooter_code must match this lock's code --- */
    code_len = strlen(my_scooter_code);
    if (field_len[0] != code_len) return 0;
    if (!ct_memeq(field_start[0], my_scooter_code, code_len)) return 0;

    /* --- Gate 2: exp must be > now_unix --- */
    if (!parse_uint64(field_start[3], field_len[3], &exp_val)) return 0;
    if (exp_val <= now_unix) return 0;

    /* --- All checks passed --- */
    return 1;
}

/* --------------------------------------------------------------------------
 * skooti_parse_jti — extract jti from a verified token (field [4])
 * -------------------------------------------------------------------------- */

int skooti_parse_jti(const char *token, char *jti_out, size_t jti_out_sz)
{
    size_t  token_len;
    size_t  dot_pos;
    size_t  msg_len;
    const char *msg;
    const char *p;
    size_t  remaining;
    int     f;

    if (!token || !jti_out || jti_out_sz == 0) return 0;

    token_len = strnlen(token, SKOOTI_TOKEN_MAX + 1);
    if (token_len == 0 || token_len > SKOOTI_TOKEN_MAX) return 0;

    /* Find last '.' */
    dot_pos = token_len;
    {
        size_t i;
        for (i = 0; i < token_len; i++) {
            if (token[i] == '.') dot_pos = i;
        }
    }
    if (dot_pos == token_len) return 0;

    msg     = token;
    msg_len = dot_pos;
    p       = msg;
    remaining = msg_len;

    /* Skip 4 pipe-delimited fields to reach jti (field[4]) */
    for (f = 0; f < 4; f++) {
        size_t j;
        const char *pipe = NULL;
        for (j = 0; j < remaining; j++) {
            if (p[j] == '|') { pipe = p + j; break; }
        }
        if (!pipe) return 0;
        p         = pipe + 1;
        remaining = msg_len - (size_t)(p - msg);
    }

    /* remaining is the jti length */
    if (remaining == 0 || remaining >= jti_out_sz) return 0;
    memcpy(jti_out, p, remaining);
    jti_out[remaining] = '\0';
    return 1;
}
