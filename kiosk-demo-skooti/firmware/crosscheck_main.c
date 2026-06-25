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
    0x88, 0x57, 0x88, 0x0d, 0x21, 0xf8, 0x7b, 0x85,
    0x87, 0x2f, 0x31, 0xae, 0xea, 0x8d, 0x00, 0x24,
    0xac, 0xeb, 0xb2, 0xfd, 0xf9, 0x33, 0xb2, 0x5a,
    0x47, 0x9f, 0x4f, 0x9e, 0x80, 0xba, 0xbe, 0xfd
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
