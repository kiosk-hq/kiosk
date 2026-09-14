/*
 * crosscheck_main.c — verify a Ruby-signed token using the C Ed25519 verifier.
 *
 * Used by `make crosscheck`, two ways:
 *   ./host_test_crosscheck "<wire_token>"     — the token as one argv word
 *   ./host_test_crosscheck --file <path>      — the token as the file's bytes
 *
 * Proves that the C firmware verifier accepts a token freshly signed by the
 * Ruby OpenSSL Ed25519 key (the same key the Kiosk server uses), and answers
 * for every vector crosscheck_grammar.rb runs. Exit status IS the verdict:
 * 0 accepted, 1 refused, 2 usage.
 *
 * WHY THE FILE MODE EXISTS. A rental token is a byte string, and one byte
 * cannot travel through argv at all: execve() delimits arguments with NUL, so
 * a token holding a NUL can only be handed to this program in a file. That
 * byte is not a curiosity — it is the one input where the C reader and a Ruby
 * reader cannot even see the same token, because skooti_verify_token takes a
 * `const char *` and stops at the first NUL while a Ruby String carries it and
 * reads on. The file mode reproduces the board exactly: the sketch does
 * `std::string val = pChar->getValue(); const char *token = val.c_str();`, so
 * a BLE write with a NUL in it reaches the verifier as the prefix before it.
 * This reads the file whole, appends the terminator std::string keeps, and
 * passes the same `const char *`.
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
#include <string.h>

/* Dev public key — 32 raw bytes */
static const uint8_t SKOOTI_PUBKEY[32] = {
    0xb3, 0x9f, 0x3a, 0x03, 0x33, 0xc6, 0x62, 0xd3,
    0x93, 0x76, 0x84, 0xf2, 0x1c, 0x91, 0xf7, 0x72,
    0x21, 0x61, 0xf8, 0xb0, 0xb4, 0xf4, 0xa7, 0x9b,
    0x33, 0x6b, 0x46, 0x3e, 0xb8, 0xf5, 0x70, 0xf4
};

#define CROSSCHECK_NOW ((uint64_t)1750001800ULL)

/* Room for any vector the grammar set can build, over-cap ones included, plus
 * the terminator. A file longer than this is a usage error, not a verdict. */
#define TOKEN_BUF 4096

static char g_token[TOKEN_BUF];

/*
 * read_token_file — slurp path into g_token and NUL-terminate it.
 * Returns the byte count read, or (size_t)-1 if the file cannot be read or
 * does not fit. The terminator is appended the way std::string::c_str() does
 * on the board, and is NOT counted: the count is the bytes that arrived.
 */
static size_t read_token_file(const char *path)
{
    FILE  *f;
    size_t n;

    f = fopen(path, "rb");
    if (!f) return (size_t)-1;

    n = fread(g_token, 1, sizeof(g_token) - 1, f);

    /* Not at EOF means the file is larger than the buffer. */
    if (!feof(f)) { fclose(f); return (size_t)-1; }
    fclose(f);

    g_token[n] = '\0';
    return n;
}

int main(int argc, char *argv[])
{
    const char *token;
    size_t      token_len;
    int         result;

    if (argc == 3 && strcmp(argv[1], "--file") == 0) {
        token_len = read_token_file(argv[2]);
        if (token_len == (size_t)-1) {
            fprintf(stderr, "%s: cannot read token file %s\n", argv[0], argv[2]);
            return 2;
        }
        token = g_token;
    } else if (argc == 2) {
        token     = argv[1];
        token_len = strlen(argv[1]);
    } else {
        fprintf(stderr, "usage: %s <wire_token> | %s --file <path>\n", argv[0], argv[0]);
        return 2;
    }

    /* The length-aware entry point, which is what the sketch calls with the
     * BLE write's own size — so a token holding a NUL is refused here exactly
     * as it is on the board, rather than verified as the prefix before it. */
    result = skooti_verify_wire(SKOOTI_PUBKEY, token, token_len, "SK-001", CROSSCHECK_NOW);

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
