/*
 * crosscheck_main.c — verify a Ruby-signed token using the C Ed25519 verifier.
 *
 * Used by `make crosscheck` (invoked as: ./host_test_crosscheck "<wire_token>")
 *
 * Proves that the C firmware verifier accepts a token freshly signed by the
 * Ruby OpenSSL Ed25519 key (the same key the Kiosk server uses).
 *
 * The token is expected to have:
 *   scooter_code = "SK-001"
 *   exp          = 1750001900
 * and is verified with now = 1750001800 (inside the window).
 */

#include "verify.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

/* Dev public key — 32 raw bytes */
static const uint8_t SKOOTI_PUBKEY[32] = {
    0xb3, 0x9f, 0x3a, 0x03, 0x33, 0xc6, 0x62, 0xd3,
    0x93, 0x76, 0x84, 0xf2, 0x1c, 0x91, 0xf7, 0x72,
    0x21, 0x61, 0xf8, 0xb0, 0xb4, 0xf4, 0xa7, 0x9b,
    0x33, 0x6b, 0x46, 0x3e, 0xb8, 0xf5, 0x70, 0xf4
};

#define CROSSCHECK_NOW ((uint64_t)1750001800ULL)

int main(int argc, char *argv[])
{
    int result;

    if (argc != 2) {
        fprintf(stderr, "usage: %s <wire_token>\n", argv[0]);
        return 2;
    }

    result = skooti_verify_token(SKOOTI_PUBKEY, argv[1], "SK-001", CROSSCHECK_NOW);

    if (result == 1) {
        printf("  C verify result: 1\n");
        printf("  MATCH — C verifier accepts Ruby/OpenSSL-signed token ✓\n");
        return 0;
    } else {
        printf("  C verify result: 0\n");
        printf("  MISMATCH — C verifier REJECTED Ruby/OpenSSL-signed token ✗\n");
        return 1;
    }
}
