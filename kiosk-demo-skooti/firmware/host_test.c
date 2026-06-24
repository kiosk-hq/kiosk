/*
 * host_test.c — crypto proof: firmware verify matches server (Plan 4 Part C)
 *
 * Compile and run via:  make test
 *
 * This test does NOT require an ESP32 board. It exercises the same
 * hmac_sha256.c + verify.c that skooti_lock.ino will link, proving the
 * firmware's cryptographic contract matches the Kiosk server (Ruby/OpenSSL)
 * without any hardware.
 *
 * Test vectors (from Plan 4 Part A / A3 + independently confirmed):
 *
 *   master_key       = "dev-master-key-0001"         (server-only; not in firmware)
 *   scooter_code     = "SK-001"
 *   K_lock (32 bytes)= d147ea9da6b6957f83e46a58cb3e7aa56e4025497143b0897f68aa05e2fd842a
 *   nonce_hex        = "00112233445566778899aabbccddeeff"
 *   reservation_id   = "resv-1"
 *   signed message   = "SK-001|00112233445566778899aabbccddeeff|resv-1"
 *   expected mac     = 896eec16ca0d164293762269f0d34c319a41b4a463bedc2ce11f3269a49e9b1f
 */

#include "verify.h"
#include "hmac_sha256.h"

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
 * Test vectors
 * -------------------------------------------------------------------------- */

/* K_lock = HMAC-SHA256("dev-master-key-0001", "SK-001")               */
/* = d147ea9da6b6957f83e46a58cb3e7aa56e4025497143b0897f68aa05e2fd842a  */
static const uint8_t K_LOCK[32] = {
    0xd1, 0x47, 0xea, 0x9d, 0xa6, 0xb6, 0x95, 0x7f,
    0x83, 0xe4, 0x6a, 0x58, 0xcb, 0x3e, 0x7a, 0xa5,
    0x6e, 0x40, 0x25, 0x49, 0x71, 0x43, 0xb0, 0x89,
    0x7f, 0x68, 0xaa, 0x05, 0xe2, 0xfd, 0x84, 0x2a
};

#define SCOOTER_CODE   "SK-001"
#define NONCE_HEX      "00112233445566778899aabbccddeeff"
#define RESERVATION_ID "resv-1"
#define EXPECTED_MAC   "896eec16ca0d164293762269f0d34c319a41b4a463bedc2ce11f3269a49e9b1f"

/* --------------------------------------------------------------------------
 * bin_to_hex (local copy for test output — keeps test self-contained)
 * -------------------------------------------------------------------------- */
static void bin_to_hex_local(const uint8_t *src, size_t len, char *dst)
{
    const char *h = "0123456789abcdef";
    size_t i;
    for (i = 0; i < len; i++) {
        dst[2*i]   = h[(src[i] >> 4) & 0x0F];
        dst[2*i+1] = h[ src[i]        & 0x0F];
    }
    dst[2*len] = '\0';
}

/* --------------------------------------------------------------------------
 * Tests
 * -------------------------------------------------------------------------- */

/*
 * Test 1 — direct HMAC-SHA256 computation matches expected MAC.
 * Builds the message manually and calls hmac_sha256().
 */
static void test_direct_hmac(void)
{
    const char *msg = SCOOTER_CODE "|" NONCE_HEX "|" RESERVATION_ID;
    uint8_t computed[32];
    char    hex[65];

    printf("\n[1] Direct HMAC-SHA256 computation\n");

    hmac_sha256(K_LOCK, 32, (const uint8_t *)msg, strlen(msg), computed);
    bin_to_hex_local(computed, 32, hex);

    printf("  computed mac : %s\n", hex);
    printf("  expected mac : %s\n", EXPECTED_MAC);

    check(strcmp(hex, EXPECTED_MAC) == 0,
          "computed mac == expected mac (896eec16...)");
}

/*
 * Test 2 — skooti_verify_unlock() accepts the correct MAC (returns 1).
 */
static void test_verify_correct_mac(void)
{
    int result;
    printf("\n[2] skooti_verify_unlock — correct MAC\n");

    result = skooti_verify_unlock(K_LOCK,
                                  SCOOTER_CODE,
                                  NONCE_HEX,
                                  RESERVATION_ID,
                                  EXPECTED_MAC);

    printf("  verify result: %d (expected 1)\n", result);
    check(result == 1, "correct MAC accepted (return 1)");
}

/*
 * Test 3 — skooti_verify_unlock() rejects a single flipped hex digit.
 * Flip the very first character of the MAC.
 */
static void test_verify_flipped_mac(void)
{
    char   bad_mac[65];
    int    result;

    printf("\n[3] skooti_verify_unlock — single flipped hex char in MAC\n");

    memcpy(bad_mac, EXPECTED_MAC, 65);
    /* Flip first char: '8' → '9' */
    bad_mac[0] = (bad_mac[0] == '8') ? '9' : '8';

    printf("  original : %s\n", EXPECTED_MAC);
    printf("  tampered : %s\n", bad_mac);

    result = skooti_verify_unlock(K_LOCK,
                                  SCOOTER_CODE,
                                  NONCE_HEX,
                                  RESERVATION_ID,
                                  bad_mac);

    printf("  verify result: %d (expected 0)\n", result);
    check(result == 0, "tampered MAC rejected (return 0)");
}

/*
 * Test 4 — skooti_verify_unlock() rejects a different nonce.
 * The lock issues a new nonce per session; a MAC computed for a different
 * nonce must not validate — this is the replay / wrong-session guard.
 */
static void test_verify_wrong_nonce(void)
{
    int result;
    /* nonce with last byte changed: ...ef → ...00 */
    const char *wrong_nonce = "00112233445566778899aabbccddeeff";
    const char *different_nonce = "ffffffffffffffffffffffffffffffff";
    printf("\n[4] skooti_verify_unlock — wrong nonce\n");
    printf("  mac was computed for nonce: %s\n", wrong_nonce);
    printf("  verifying with nonce:       %s\n", different_nonce);

    result = skooti_verify_unlock(K_LOCK,
                                  SCOOTER_CODE,
                                  different_nonce,
                                  RESERVATION_ID,
                                  EXPECTED_MAC);

    printf("  verify result: %d (expected 0)\n", result);
    check(result == 0, "wrong nonce rejected (return 0)");
}

/*
 * Test 5 — NULL / empty mac_hex rejected.
 */
static void test_verify_bad_input(void)
{
    int result;
    printf("\n[5] skooti_verify_unlock — bad inputs\n");

    result = skooti_verify_unlock(K_LOCK, SCOOTER_CODE, NONCE_HEX,
                                  RESERVATION_ID, "short");
    check(result == 0, "mac_hex shorter than 64 chars rejected");

    result = skooti_verify_unlock(K_LOCK, SCOOTER_CODE, NONCE_HEX,
                                  RESERVATION_ID, NULL);
    check(result == 0, "NULL mac_hex rejected");
}

/*
 * Test 6 — K_lock derivation crosscheck.
 * Compute K_lock from the master key in C and compare to the known vector.
 * (The server does exactly this: K_lock = HMAC-SHA256(master_key, scooter_code))
 */
static void test_klock_derivation(void)
{
    const char *master_key  = "dev-master-key-0001";
    const char *scooter_code = "SK-001";
    uint8_t    derived[32];
    char       hex[65];

    const char *EXPECTED_KLOCK =
        "d147ea9da6b6957f83e46a58cb3e7aa56e4025497143b0897f68aa05e2fd842a";

    printf("\n[6] K_lock derivation: HMAC-SHA256(master_key, scooter_code)\n");

    hmac_sha256((const uint8_t *)master_key,  strlen(master_key),
                (const uint8_t *)scooter_code, strlen(scooter_code),
                derived);
    bin_to_hex_local(derived, 32, hex);

    printf("  derived K_lock : %s\n", hex);
    printf("  expected K_lock: %s\n", EXPECTED_KLOCK);

    check(strcmp(hex, EXPECTED_KLOCK) == 0,
          "C-derived K_lock matches known vector");

    /* Also confirm the baked K_LOCK[] constant is correct */
    check(memcmp(derived, K_LOCK, 32) == 0,
          "baked K_LOCK[] constant matches C-derived K_lock");
}

/* --------------------------------------------------------------------------
 * main
 * -------------------------------------------------------------------------- */
int main(void)
{
    printf("=== skooti firmware crypto host test ===\n");
    printf("Vectors: master_key=\"dev-master-key-0001\" scooter=\"SK-001\"\n");

    test_direct_hmac();
    test_verify_correct_mac();
    test_verify_flipped_mac();
    test_verify_wrong_nonce();
    test_verify_bad_input();
    test_klock_derivation();

    printf("\n=== Results: %d passed, %d failed ===\n", g_pass, g_fail);

    if (g_fail > 0) {
        printf("FAIL\n");
        return 1;
    }
    printf("ALL PASS\n");
    return 0;
}
