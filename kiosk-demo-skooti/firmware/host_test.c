/*
 * host_test.c — offline Ed25519 crypto proof: firmware verify matches server
 *
 * Compile and run via:  make test
 *
 * This test does NOT require an ESP32 board. It exercises the same
 * ed25519/ + verify.c + jti_store.c that skooti_lock.ino will link, proving
 * that the firmware's cryptographic contract matches the Kiosk server
 * (Ruby/OpenSSL) without any hardware.
 *
 * =========================================================================
 * KNOWN-ANSWER VECTOR — DO NOT CHANGE
 * =========================================================================
 *
 * Dev public key (32 bytes hex):
 *   b39f3a0333c662d3937684f21c91f7722161f8b0b4f4a79b336b463eb8f570f4
 *
 * Fixed inputs:
 *   scooter_code   = "SK-001"
 *   reservation_id = "resv-1"
 *   iat            = 1750000000
 *   exp            = 1750000900
 *   jti            = "aabbccddeeff00112233445566778899"
 *
 * message (signed bytes) — with domain-separation tag:
 *   "kiosk-rental-v1|SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899"
 *
 * signature (base64url, no padding):
 *   SDKHoyU3zzqvpVCwOcKf75EMJCyNKaxuRbvY3HmuM-q--ZaMEdeSmBi40JgZyhvBuL4A15xlupYqlGMfCnROCg
 *
 * wire token = "<message>.<sig>"
 */

#include "verify.h"
#include "jti_store.h"
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
    0xb3, 0x9f, 0x3a, 0x03, 0x33, 0xc6, 0x62, 0xd3,
    0x93, 0x76, 0x84, 0xf2, 0x1c, 0x91, 0xf7, 0x72,
    0x21, 0x61, 0xf8, 0xb0, 0xb4, 0xf4, 0xa7, 0x9b,
    0x33, 0x6b, 0x46, 0x3e, 0xb8, 0xf5, 0x70, 0xf4
};

#define SCOOTER_CODE "SK-001"

/* wire token: domain-separation tag + 6 pipe fields */
#define WIRE_TOKEN \
    "kiosk-rental-v1|SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899" \
    "." \
    "SDKHoyU3zzqvpVCwOcKf75EMJCyNKaxuRbvY3HmuM-q--ZaMEdeSmBi40JgZyhvBuL4A15xlupYqlGMfCnROCg"

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
 * Test 5 — oversized sig field → returns 0, NO CRASH (buffer-overflow regression)
 *
 * Security regression: pre-fix, b64url_decode had no destination-capacity bound.
 * A token whose sig field is ~400 valid base64url characters would decode to ~300
 * bytes, overflowing sig[64] on the stack with attacker-controlled bytes.
 * Post-fix: the early sig_b64_len > 88 guard and the dst_cap == 64 bound in
 * b64url_decode must both reject this cleanly (return 0) without any crash or
 * ASan report.  Build with -fsanitize=address (make test-asan) to confirm.
 *
 * Token constructed as: valid KAT message + "." + 400 'A' characters.
 * 400 'A' chars are valid base64url (all in [A-Z]) — the old code would try to
 * write ~300 decoded bytes; the new code stops at 64 and returns 0.
 */
static void test_oversized_sig(void)
{
    /* Build: "<valid message>." + 400 'A' chars */
    static const char msg[] =
        "kiosk-rental-v1|SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899";
    /* 400 valid base64url 'A' chars decode to 300 bytes — must be rejected */
    static const char oversized_sig[401] =
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    ; /* 5 * 80 = 400 chars + NUL */

    char token[600];
    size_t msg_len = strlen(msg);
    size_t sig_len = strlen(oversized_sig); /* 400 */
    int result;

    printf("\n[5] Oversized sig field (~400 'A' chars → ~300 decoded bytes)"
           " → expect 0, no crash/overflow\n");

    if (msg_len + 1 + sig_len + 1 > sizeof(token)) {
        printf("  SKIP (token too long for local buffer)\n");
        g_fail++;
        return;
    }
    memcpy(token, msg, msg_len);
    token[msg_len] = '.';
    memcpy(token + msg_len + 1, oversized_sig, sig_len);
    token[msg_len + 1 + sig_len] = '\0';

    printf("  sig field length: %zu chars\n", sig_len);
    result = skooti_verify_token(SKOOTI_PUBKEY, token, SCOOTER_CODE, NOW_FRESH);
    printf("  result: %d\n", result);
    check(result == 0, "oversized sig (400 base64url chars) → 0, no crash");
}

/*
 * Test 6 — malformed / truncated tokens → return 0, no crash
 */
static void test_malformed_tokens(void)
{
    int result;
    printf("\n[6] Malformed / truncated tokens → expect 0, no crash\n");

    /* 5a — empty string */
    result = skooti_verify_token(SKOOTI_PUBKEY, "", SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "empty token → 0");

    /* 5b — no dot at all (message without sig portion) */
    result = skooti_verify_token(SKOOTI_PUBKEY,
        "kiosk-rental-v1|SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899",
        SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "missing dot (no sig) → 0");

    /* 5c — message with fewer than 6 fields (only 2 here) */
    result = skooti_verify_token(SKOOTI_PUBKEY,
        "kiosk-rental-v1|SK-001.b-8ZCqcN1FZAXn4YbXPJXasTED2rwq0DSOXrcRSjI9aj",
        SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "only 2 message fields → 0");

    /* 5d — sig shorter than 64 decoded bytes */
    result = skooti_verify_token(SKOOTI_PUBKEY,
        "kiosk-rental-v1|SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899.dG9vc2hvcnQ",
        SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "too-short sig → 0");

    /* 5e — NULL token */
    result = skooti_verify_token(SKOOTI_PUBKEY, NULL, SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "NULL token → 0");

    /* 5f — NULL pubkey */
    result = skooti_verify_token(NULL, WIRE_TOKEN, SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "NULL pubkey → 0");
}

/*
 * Test 7 — wrong domain-separation tag → returns 0
 *
 * A token whose message field[0] is NOT "kiosk-rental-v1" must be rejected
 * even if the signature over the (wrong-tagged) message is valid.
 *
 * Security note: we cannot produce a VALID Ed25519 sig over a wrong-tagged
 * message using the real private key in a unit test (we do not have it here).
 * Instead we construct a token with a wrong tag and the valid KAT sig — this
 * exercises the full path:
 *   1. The sig does NOT verify (the message bytes differ), so we get 0 via
 *      the Ed25519 check.  This is correct behaviour.
 *   2. Alternatively: if sig happened to match (not possible with Ed25519),
 *      the tag check would also catch it.
 * Rejecting wrong-tagged tokens is thus guaranteed by either gate.
 *
 * The crosscheck (make crosscheck) further proves that only "kiosk-rental-v1"
 * messages can produce a valid sig with the real key.
 */
static void test_wrong_domain_tag(void)
{
    int result;
    printf("\n[7] Token with wrong domain tag (\"kiosk-rental-v0\") → expect 0\n");

    /* Replace "kiosk-rental-v1" with "kiosk-rental-v0" — message bytes differ,
     * so the Ed25519 sig (from the v1-tagged KAT) cannot verify. */
    result = skooti_verify_token(SKOOTI_PUBKEY,
        "kiosk-rental-v0|SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899"
        "."
        "SDKHoyU3zzqvpVCwOcKf75EMJCyNKaxuRbvY3HmuM-q--ZaMEdeSmBi40JgZyhvBuL4A15xlupYqlGMfCnROCg",
        SCOOTER_CODE, NOW_FRESH);
    printf("  result: %d\n", result);
    check(result == 0, "wrong tag (kiosk-rental-v0) → 0");

    /* Also test a completely arbitrary tag */
    result = skooti_verify_token(SKOOTI_PUBKEY,
        "evil|SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899"
        "."
        "SDKHoyU3zzqvpVCwOcKf75EMJCyNKaxuRbvY3HmuM-q--ZaMEdeSmBi40JgZyhvBuL4A15xlupYqlGMfCnROCg",
        SCOOTER_CODE, NOW_FRESH);
    printf("  result: %d\n", result);
    check(result == 0, "arbitrary tag (\"evil\") → 0");
}

/*
 * Test 8 — field-count boundary, every vector carrying a VALID signature
 *
 * The signed message is exactly six pipe-delimited fields, and both directions
 * of that boundary belong to the PARSER. Only a token whose Ed25519 signature
 * verifies can prove the parser closes them: a wrong-count message carrying a
 * junk signature is refused by the signature gate first — case [6]/5c above is
 * that shape — so it says nothing about the count. Every vector below is signed
 * with the dev key in ../config/dev_unlock_key.pem, the same key the KAT vector
 * at the top of this file comes from, so the count is the only gate left to
 * answer. The vectors sit in the KAT window (exp=1750000900, NOW_FRESH).
 *
 * The eight-field vector is the one that carries weight. It is what the issuer
 * mints when a '|' reaches scooter_code or reservation_id — the charset
 * contract on RentalTokenIssuer.issue names that input precondition — and the
 * damage is not the extra field but the SHIFT: field[4] stops being `exp` and
 * becomes whatever the caller wrote, here 9999999999, a far-future expiry. A
 * verifier that does not count fields honours it and the 15-minute window is
 * gone. The Ruby issuer's own verifier refuses all three wrong-count messages;
 * `make crosscheck` runs the same four shapes through both halves.
 */
static void test_field_count_boundary(void)
{
    int result;

    /* 5 fields — jti absent. Signed with the dev key. */
    static const char TOKEN_5_FIELDS[] =
        "kiosk-rental-v1|SK-001|resv-1|1750000000|1750000900"
        "."
        "I7JI1fj0t5cg56pJ9NGSJIplXbw3ue5SHSGfxLJnsUAYld8mkmwSpiwq-0S4_PD-YQ0f8XFN_N2JZk2441LUCA";

    /* 7 fields — one extra field appended after the jti. Signed with the dev key. */
    static const char TOKEN_7_FIELDS[] =
        "kiosk-rental-v1|SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899|EXTRA"
        "."
        "AWMTaB9dSUOYDrzU57pUdM8d6-qi_V_Wnr8mSTSIf1BnwihkBPBQrW6Y9EO34eycd3Pl8LOlUcueJubChPCpAQ";

    /* 8 fields — reservation_id "r|1750000000|9999999999" shifts every field
     * left, so field[4] reads 9999999999 instead of the real exp. Signed with
     * the dev key, correct scooter_code in field[1]: count is the only gate
     * that can refuse it. */
    static const char TOKEN_8_FIELDS_SHIFTED[] =
        "kiosk-rental-v1|SK-001|r|1750000000|9999999999|1750000000|1750000900|aabbccddeeff00112233445566778899"
        "."
        "Uw3Kh9_cBCbjcjaCB0sFOd8v9RqSvX7o4iDarQ62ljFxE6tB2wiPL1GliDzxnfXdVZvApmR8oUasc0NMzyQOAg";

    printf("\n[8] Field-count boundary, valid signature on every vector → 5:0  6:1  7:0  8:0\n");

    result = skooti_verify_token(SKOOTI_PUBKEY, TOKEN_5_FIELDS, SCOOTER_CODE, NOW_FRESH);
    printf("  5 fields, valid sig → result: %d\n", result);
    check(result == 0, "5-field message, valid sig → 0");

    result = skooti_verify_token(SKOOTI_PUBKEY, WIRE_TOKEN, SCOOTER_CODE, NOW_FRESH);
    printf("  6 fields, valid sig → result: %d\n", result);
    check(result == 1, "6-field message, valid sig → 1");

    result = skooti_verify_token(SKOOTI_PUBKEY, TOKEN_7_FIELDS, SCOOTER_CODE, NOW_FRESH);
    printf("  7 fields, valid sig → result: %d\n", result);
    check(result == 0, "7-field message, valid sig → 0");

    result = skooti_verify_token(SKOOTI_PUBKEY, TOKEN_8_FIELDS_SHIFTED, SCOOTER_CODE, NOW_FRESH);
    printf("  8 fields (field-shift, field[4]=9999999999), valid sig → result: %d\n", result);
    check(result == 0, "8-field field-shift, valid sig → 0");
}

/*
 * Test 9 — jti_store: insert, replay detection, expiry pruning, table-full eviction
 */
static void test_jti_store(void)
{
    int r;

    printf("\n[9] jti_store: insert, replay, prune, table-full eviction\n");

    /* 9a — fresh insert: first time → 0 (new) */
    jti_store_reset();
    r = jti_seen_or_insert("aabbccddeeff00112233445566778899", 1750000900ULL, 1750000800ULL);
    check(r == 0, "jti_store: first insert → 0 (new)");

    /* 9b — replay: same jti, exp > now → 1 (seen, reject) */
    r = jti_seen_or_insert("aabbccddeeff00112233445566778899", 1750000900ULL, 1750000800ULL);
    check(r == 1, "jti_store: second insert same jti (exp>now) → 1 (replay rejected)");

    /* 9c — expired entry pruned: insert jti1 with exp <= now → pruned;
     * re-inserting the same jti1 returns 0 (new, not replay) */
    jti_store_reset();
    /* Insert with exp already in the past */
    r = jti_seen_or_insert("deadbeef00112233445566778899aabb",
                            1750000000ULL, /* exp */
                            1750000001ULL  /* now = exp+1 → already expired at insert time */);
    /* exp <= now at insert: entry accepted (0) but immediately eligible for pruning */
    check(r == 0, "jti_store: insert expired-at-creation → 0 (stored)");

    /* Now re-insert the same jti with now > exp → entry was pruned; returns 0 again */
    r = jti_seen_or_insert("deadbeef00112233445566778899aabb",
                            1750000000ULL,
                            1750000500ULL  /* now is well past exp */);
    check(r == 0, "jti_store: expired entry pruned → re-insert → 0 (not replay)");

    /* 9d — table-full: fill JTI_STORE_SIZE slots with distinct jtis, then add one more.
     * The oldest / smallest-exp entry is evicted; overall call returns 0 (not -1). */
    jti_store_reset();
    {
        int i;
        char jti_buf[JTI_MAX_LEN];
        int all_ok = 1;
        for (i = 0; i < JTI_STORE_SIZE; i++) {
            /* Generate a distinct 32-char hex jti (zero-padded index) */
            int j;
            for (j = 0; j < 32; j++) jti_buf[j] = '0';
            /* Write decimal index into last 8 chars */
            {
                int val = i;
                int k;
                for (k = 31; k >= 24 && val > 0; k--) {
                    jti_buf[k] = '0' + (val % 10);
                    val /= 10;
                }
            }
            jti_buf[32] = '\0';
            r = jti_seen_or_insert(jti_buf, (uint64_t)(1750001000 + i), 1750000800ULL);
            if (r != 0) { all_ok = 0; break; }
        }
        check(all_ok, "jti_store: fill 64 slots → all return 0 (new)");

        /* One more — table full, must evict and return 0 (not -1) */
        r = jti_seen_or_insert("ffffffffffffffffffffffffffffffff",
                                1750002000ULL, 1750000800ULL);
        check(r == 0, "jti_store: table-full + evict oldest → 0 (new, not error)");
    }

    /* 9e — invalid argument: NULL jti → -1 */
    r = jti_seen_or_insert(NULL, 1750000900ULL, 1750000800ULL);
    check(r == -1, "jti_store: NULL jti → -1 (invalid arg)");

    /* 9f — invalid argument: empty jti → -1 */
    r = jti_seen_or_insert("", 1750000900ULL, 1750000800ULL);
    check(r == -1, "jti_store: empty jti → -1 (invalid arg)");

    /* 9g — invalid argument: jti too long (>= JTI_MAX_LEN chars) → -1 */
    r = jti_seen_or_insert("aabbccddeeff00112233445566778899X" /* 33 chars */,
                            1750000900ULL, 1750000800ULL);
    check(r == -1, "jti_store: jti too long (33 chars) → -1 (invalid arg)");
}

/* --------------------------------------------------------------------------
 * main
 * -------------------------------------------------------------------------- */

int main(void)
{
    printf("=== skooti firmware Ed25519 host test (offline Ed25519 rental token) ===\n");
    printf("Public key : b39f3a0333c662d3937684f21c91f7722161f8b0b4f4a79b336b463eb8f570f4\n");
    printf("Scooter    : %s\n", SCOOTER_CODE);

    test_correct_token_fresh();
    test_expired_token();
    test_wrong_scooter_code();
    test_flipped_sig();
    test_oversized_sig();
    test_malformed_tokens();
    test_wrong_domain_tag();
    test_field_count_boundary();
    test_jti_store();

    printf("\n=== Results: %d passed, %d failed ===\n", g_pass, g_fail);

    if (g_fail > 0) {
        printf("FAIL\n");
        return 1;
    }
    printf("ALL PASS\n");
    return 0;
}
