/*
 * host_test.c — Arch 2 crypto proof: firmware Ed25519 verify matches server
 *
 * Compile and run via:  make test
 *
 * This test does NOT require an ESP32 board. It exercises the same
 * ed25519/ + verify.c that skooti_lock.ino will link, proving that the
 * firmware's cryptographic contract matches the Kiosk server (Ruby/OpenSSL)
 * without any hardware.
 *
 * =========================================================================
 * KNOWN-ANSWER VECTOR (from Plan 4.2 T1 — DO NOT CHANGE)
 * =========================================================================
 *
 * Dev public key (32 bytes hex):
 *   8857880d21f87b85872f31aeea8d0024acebb2fdf933b25a479f4f9e80babefd
 *
 * Fixed inputs:
 *   scooter_code   = "SK-001"
 *   reservation_id = "resv-1"
 *   iat            = 1750000000
 *   exp            = 1750000900
 *   jti            = "aabbccddeeff00112233445566778899"
 *
 * message (signed bytes):
 *   "SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899"
 *
 * signature (base64url, no padding):
 *   b-8ZCqcN1FZAXn4YbXPJXasTED2rwq0DSOXrcRSjI9ajReEBb9Y3m3YSHgNJEElC
 *   HSwnEGGYbNGiEWRCZD_yBw
 *
 * wire token = "<message>.<sig>"
 */

#include "verify.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

/* --------------------------------------------------------------------------
 * Test harness
 * -------------------------------------------------------------------------- */

static int g_pass = 0;
static int g_fail = 0;

static void check(int condition, const char *description)
{
    if (condition) {
        printf("  PASS  %s\n", description);
        g_pass++;
    } else {
        printf("  FAIL  %s\n", description);
        g_fail++;
    }
}

/* --------------------------------------------------------------------------
 * Known-answer vector (T1 firmware fixtures)
 * -------------------------------------------------------------------------- */

/* Dev public key — 32 raw bytes (matches hex above) */
static const uint8_t SKOOTI_PUBKEY[32] = {
    0x88, 0x57, 0x88, 0x0d, 0x21, 0xf8, 0x7b, 0x85,
    0x87, 0x2f, 0x31, 0xae, 0xea, 0x8d, 0x00, 0x24,
    0xac, 0xeb, 0xb2, 0xfd, 0xf9, 0x33, 0xb2, 0x5a,
    0x47, 0x9f, 0x4f, 0x9e, 0x80, 0xba, 0xbe, 0xfd
};

#define SCOOTER_CODE "SK-001"

#define WIRE_TOKEN \
    "SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899" \
    "." \
    "b-8ZCqcN1FZAXn4YbXPJXasTED2rwq0DSOXrcRSjI9ajReEBb9Y3m3YSHgNJEElCHSwnEGGYbNGiEWRCZD_yBw"

/* Timestamp inside the validity window (exp=1750000900, now=1750000800) */
#define NOW_FRESH   ((uint64_t)1750000800ULL)
/* Timestamp after expiry */
#define NOW_EXPIRED ((uint64_t)1750000901ULL)

/* --------------------------------------------------------------------------
 * Tests
 * -------------------------------------------------------------------------- */

/*
 * Test 1 — correct token, now < exp → returns 1
 */
static void test_correct_token_fresh(void)
{
    int result;
    printf("\n[1] Correct token, now=%llu (< exp=1750000900) → expect 1\n",
           (unsigned long long)NOW_FRESH);

    result = skooti_verify_token(SKOOTI_PUBKEY, WIRE_TOKEN, SCOOTER_CODE, NOW_FRESH);
    printf("  result: %d\n", result);
    check(result == 1, "correct token + fresh now → 1");
}

/*
 * Test 2 — correct token, now > exp → returns 0 (expired)
 */
static void test_expired_token(void)
{
    int result;
    printf("\n[2] Correct token, now=%llu (> exp=1750000900) → expect 0\n",
           (unsigned long long)NOW_EXPIRED);

    result = skooti_verify_token(SKOOTI_PUBKEY, WIRE_TOKEN, SCOOTER_CODE, NOW_EXPIRED);
    printf("  result: %d\n", result);
    check(result == 0, "expired token (now > exp) → 0");
}

/*
 * Test 3 — correct token, wrong scooter_code → returns 0
 */
static void test_wrong_scooter_code(void)
{
    int result;
    printf("\n[3] Correct token, my_scooter_code=\"SK-999\" → expect 0\n");

    result = skooti_verify_token(SKOOTI_PUBKEY, WIRE_TOKEN, "SK-999", NOW_FRESH);
    printf("  result: %d\n", result);
    check(result == 0, "wrong scooter_code → 0");
}

/*
 * Test 4 — flip one base64url character in the sig → returns 0
 */
static void test_flipped_sig(void)
{
    char   bad_token[600];
    size_t tok_len;
    int    result;
    /* Find the last '.' to locate the sig portion */
    const char *dot;
    size_t      dot_offset;

    printf("\n[4] Token with one flipped base64url char in sig → expect 0\n");

    tok_len = strlen(WIRE_TOKEN);
    if (tok_len >= sizeof(bad_token)) {
        printf("  SKIP (token too long for buffer)\n");
        g_fail++;
        return;
    }
    memcpy(bad_token, WIRE_TOKEN, tok_len + 1);

    /* Find last '.' */
    dot = NULL;
    {
        size_t i;
        for (i = 0; i < tok_len; i++) {
            if (bad_token[i] == '.') dot = bad_token + i;
        }
    }
    if (!dot) {
        printf("  SKIP (no dot found)\n");
        g_fail++;
        return;
    }
    dot_offset = (size_t)(dot - bad_token);

    /* Flip the first character of the sig: 'b' → 'c' */
    bad_token[dot_offset + 1] = (bad_token[dot_offset + 1] == 'b') ? 'c' : 'b';

    printf("  original sig[0]: '%c'  flipped to: '%c'\n",
           WIRE_TOKEN[dot_offset + 1], bad_token[dot_offset + 1]);

    result = skooti_verify_token(SKOOTI_PUBKEY, bad_token, SCOOTER_CODE, NOW_FRESH);
    printf("  result: %d\n", result);
    check(result == 0, "flipped sig byte → 0");
}

/*
 * Test 5 — malformed / truncated tokens → return 0, no crash
 */
static void test_malformed_tokens(void)
{
    int result;
    printf("\n[5] Malformed / truncated tokens → expect 0, no crash\n");

    /* 5a — empty string */
    result = skooti_verify_token(SKOOTI_PUBKEY, "", SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "empty token → 0");

    /* 5b — no dot at all */
    result = skooti_verify_token(SKOOTI_PUBKEY,
        "SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899",
        SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "missing dot (no sig) → 0");

    /* 5c — message with fewer than 5 fields */
    result = skooti_verify_token(SKOOTI_PUBKEY,
        "SK-001|resv-1.b-8ZCqcN1FZAXn4YbXPJXasTED2rwq0DSOXrcRSjI9aj",
        SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "only 2 message fields → 0");

    /* 5d — sig shorter than 64 decoded bytes */
    result = skooti_verify_token(SKOOTI_PUBKEY,
        "SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899.dG9vc2hvcnQ",
        SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "too-short sig → 0");

    /* 5e — NULL token */
    result = skooti_verify_token(SKOOTI_PUBKEY, NULL, SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "NULL token → 0");

    /* 5f — NULL pubkey */
    result = skooti_verify_token(NULL, WIRE_TOKEN, SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "NULL pubkey → 0");
}

/* --------------------------------------------------------------------------
 * main
 * -------------------------------------------------------------------------- */

int main(void)
{
    printf("=== skooti firmware Ed25519 host test (Arch 2) ===\n");
    printf("Public key : 8857880d21f87b85872f31aeea8d0024acebb2fdf933b25a479f4f9e80babefd\n");
    printf("Scooter    : %s\n", SCOOTER_CODE);

    test_correct_token_fresh();
    test_expired_token();
    test_wrong_scooter_code();
    test_flipped_sig();
    test_malformed_tokens();

    printf("\n=== Results: %d passed, %d failed ===\n", g_pass, g_fail);

    if (g_fail > 0) {
        printf("FAIL\n");
        return 1;
    }
    printf("ALL PASS\n");
    return 0;
}
