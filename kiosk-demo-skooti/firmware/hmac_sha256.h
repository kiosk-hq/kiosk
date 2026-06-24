/*
 * hmac_sha256.h — portable, dependency-free SHA-256 + HMAC-SHA256
 *
 * Compiles on:
 *   - Host (clang / gcc, C89/C99)
 *   - ESP32-C3 (Arduino-ESP32, ESP-IDF toolchain)
 *
 * No platform headers required; only <stdint.h> and <string.h>.
 *
 * Usage:
 *   uint8_t out[32];
 *   hmac_sha256(key, key_len, msg, msg_len, out);
 */
#ifndef HMAC_SHA256_H
#define HMAC_SHA256_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* SHA-256 context */
typedef struct {
    uint32_t state[8];
    uint8_t  buf[64];
    uint32_t buf_len;
    uint64_t total_len;
} sha256_ctx_t;

void sha256_init(sha256_ctx_t *ctx);
void sha256_update(sha256_ctx_t *ctx, const uint8_t *data, size_t len);
void sha256_final(sha256_ctx_t *ctx, uint8_t out[32]);

/* One-shot HMAC-SHA256.
 * key      : raw key bytes (any length; >64 bytes will be hashed)
 * key_len  : length of key in bytes
 * msg      : message bytes
 * msg_len  : length of message in bytes
 * out      : 32-byte output buffer
 */
void hmac_sha256(const uint8_t *key, size_t key_len,
                 const uint8_t *msg, size_t msg_len,
                 uint8_t out[32]);

#ifdef __cplusplus
}
#endif

#endif /* HMAC_SHA256_H */
