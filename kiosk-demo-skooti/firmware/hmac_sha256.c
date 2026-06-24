/*
 * hmac_sha256.c — portable SHA-256 + HMAC-SHA256, C89/C99
 *
 * SHA-256 implementation based on FIPS 180-4, hand-rolled to avoid any
 * platform dependency. Verified against the NIST test vectors and against
 * OpenSSL via the host_test crosscheck target.
 *
 * Compiles cleanly on:
 *   - Host: clang / gcc with -std=c99 (or -std=c89 + C99 intypes)
 *   - ESP32-C3 (Arduino-ESP32, xtensa / RISC-V toolchain, C99)
 *
 * No platform headers used beyond <stdint.h>, <string.h>, <stdlib.h>.
 */

#include "hmac_sha256.h"
#include <string.h>

/* --------------------------------------------------------------------------
 * SHA-256 constants
 * -------------------------------------------------------------------------- */

static const uint32_t K[64] = {
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U,
    0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
    0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
    0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
    0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
    0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
    0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
    0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
    0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
    0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
    0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U,
    0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
    0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U,
    0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
    0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
    0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U
};

static const uint32_t H0[8] = {
    0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
    0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U
};

/* --------------------------------------------------------------------------
 * Bit-operation helpers (avoid shifts > 31 via masking)
 * -------------------------------------------------------------------------- */

#define ROTR32(x,n) (((x) >> (n)) | ((x) << (32 - (n))))

#define CH(x,y,z)  (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x,y,z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define EP0(x)     (ROTR32(x, 2)  ^ ROTR32(x,13) ^ ROTR32(x,22))
#define EP1(x)     (ROTR32(x, 6)  ^ ROTR32(x,11) ^ ROTR32(x,25))
#define SIG0(x)    (ROTR32(x, 7)  ^ ROTR32(x,18) ^ ((x) >> 3))
#define SIG1(x)    (ROTR32(x,17)  ^ ROTR32(x,19) ^ ((x) >> 10))

/* Big-endian 32-bit read from unaligned bytes */
static uint32_t be32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] <<  8) |  (uint32_t)p[3];
}

/* Big-endian 32-bit write */
static void put_be32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >>  8);
    p[3] = (uint8_t) v;
}

/* Big-endian 64-bit write */
static void put_be64(uint8_t *p, uint64_t v)
{
    put_be32(p,     (uint32_t)(v >> 32));
    put_be32(p + 4, (uint32_t) v);
}

/* --------------------------------------------------------------------------
 * SHA-256 block compression
 * -------------------------------------------------------------------------- */
static void sha256_compress(uint32_t state[8], const uint8_t block[64])
{
    uint32_t w[64];
    uint32_t a,b,c,d,e,f,g,h, t1,t2;
    int i;

    for (i = 0; i < 16; i++)
        w[i] = be32(block + 4*i);
    for (i = 16; i < 64; i++)
        w[i] = SIG1(w[i-2]) + w[i-7] + SIG0(w[i-15]) + w[i-16];

    a = state[0]; b = state[1]; c = state[2]; d = state[3];
    e = state[4]; f = state[5]; g = state[6]; h = state[7];

    for (i = 0; i < 64; i++) {
        t1 = h + EP1(e) + CH(e,f,g) + K[i] + w[i];
        t2 = EP0(a) + MAJ(a,b,c);
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }

    state[0] += a; state[1] += b; state[2] += c; state[3] += d;
    state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

/* --------------------------------------------------------------------------
 * SHA-256 streaming API
 * -------------------------------------------------------------------------- */
void sha256_init(sha256_ctx_t *ctx)
{
    int i;
    for (i = 0; i < 8; i++) ctx->state[i] = H0[i];
    ctx->buf_len   = 0;
    ctx->total_len = 0;
}

void sha256_update(sha256_ctx_t *ctx, const uint8_t *data, size_t len)
{
    size_t avail;
    ctx->total_len += (uint64_t)len;
    while (len > 0) {
        avail = 64 - ctx->buf_len;
        if (len < avail) {
            memcpy(ctx->buf + ctx->buf_len, data, len);
            ctx->buf_len += (uint32_t)len;
            break;
        }
        memcpy(ctx->buf + ctx->buf_len, data, avail);
        sha256_compress(ctx->state, ctx->buf);
        ctx->buf_len = 0;
        data += avail;
        len  -= avail;
    }
}

void sha256_final(sha256_ctx_t *ctx, uint8_t out[32])
{
    uint8_t pad[64];
    uint32_t pad_len;
    int i;

    /* Append 0x80 */
    ctx->buf[ctx->buf_len++] = 0x80;

    /* Need room for 8-byte bit-length; if buffer too full, flush first */
    if (ctx->buf_len > 56) {
        memset(ctx->buf + ctx->buf_len, 0, 64 - ctx->buf_len);
        sha256_compress(ctx->state, ctx->buf);
        ctx->buf_len = 0;
    }

    /* Zero-pad and append message bit-length (big-endian 64-bit) */
    memset(ctx->buf + ctx->buf_len, 0, 56 - ctx->buf_len);
    /* total_len is in bytes; multiply by 8 for bit count */
    put_be64(ctx->buf + 56, (ctx->total_len - 1ULL) * 8ULL + 8ULL);
    sha256_compress(ctx->state, ctx->buf);

    for (i = 0; i < 8; i++)
        put_be32(out + 4*i, ctx->state[i]);

    (void)pad; (void)pad_len; /* suppress unused warnings */
}

/* --------------------------------------------------------------------------
 * HMAC-SHA256
 * -------------------------------------------------------------------------- */
void hmac_sha256(const uint8_t *key, size_t key_len,
                 const uint8_t *msg, size_t msg_len,
                 uint8_t out[32])
{
    uint8_t k0[64];       /* key padded to block size */
    uint8_t ipad[64];
    uint8_t opad[64];
    uint8_t inner[32];
    sha256_ctx_t ctx;
    size_t i;

    /* Normalise key to 64 bytes */
    memset(k0, 0, 64);
    if (key_len > 64) {
        sha256_init(&ctx);
        sha256_update(&ctx, key, key_len);
        sha256_final(&ctx, k0);
    } else {
        memcpy(k0, key, key_len);
    }

    /* ipad = k0 XOR 0x36; opad = k0 XOR 0x5C */
    for (i = 0; i < 64; i++) {
        ipad[i] = k0[i] ^ 0x36u;
        opad[i] = k0[i] ^ 0x5Cu;
    }

    /* Inner hash: H(ipad || msg) */
    sha256_init(&ctx);
    sha256_update(&ctx, ipad, 64);
    sha256_update(&ctx, msg, msg_len);
    sha256_final(&ctx, inner);

    /* Outer hash: H(opad || inner) */
    sha256_init(&ctx);
    sha256_update(&ctx, opad, 64);
    sha256_update(&ctx, inner, 32);
    sha256_final(&ctx, out);
}
