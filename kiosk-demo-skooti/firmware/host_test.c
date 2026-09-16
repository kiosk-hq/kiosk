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
 * Known-answer vector — the same message, key and signature
 * script/rental_token_issuer_kat.rb mints and prints
 * -------------------------------------------------------------------------- */

/* Dev public key — 32 raw bytes (matches hex above) */
static const uint8_t SKOOTI_PUBKEY[32] = {
    0xb3, 0x9f, 0x3a, 0x03, 0x33, 0xc6, 0x62, 0xd3,
    0x93, 0x76, 0x84, 0xf2, 0x1c, 0x91, 0xf7, 0x72,
    0x21, 0x61, 0xf8, 0xb0, 0xb4, 0xf4, 0xa7, 0x9b,
    0x33, 0x6b, 0x46, 0x3e, 0xb8, 0xf5, 0x70, 0xf4
};

#define SCOOTER_CODE "SK-001"

/* The two halves of the known-answer wire token, so the encoding tests can
 * respell the signature without retyping the message. */
#define KAT_MSG \
    "kiosk-rental-v1|SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899"
#define KAT_SIG \
    "SDKHoyU3zzqvpVCwOcKf75EMJCyNKaxuRbvY3HmuM-q--ZaMEdeSmBi40JgZyhvBuL4A15xlupYqlGMfCnROCg"

/* wire token: domain-separation tag + 6 pipe fields */
#define WIRE_TOKEN KAT_MSG "." KAT_SIG

/* Timestamp inside the validity window (exp=1750000900, now=1750000800) */
#define NOW_FRESH   ((uint64_t)1750000800ULL)
/* Timestamp after expiry */
#define NOW_EXPIRED ((uint64_t)1750000901ULL)
/* The instant exp names — the window is now < exp, so this one is spent */
#define NOW_AT_EXP  ((uint64_t)1750000900ULL)
/* The last instant inside the window */
#define NOW_LAST    ((uint64_t)1750000899ULL)

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
 * Test 9 — field CONTENT boundary, every vector carrying a VALID signature
 *
 * Test 8 above closes the field COUNT. This one closes what the fields may
 * CONTAIN, and it exists for the same reason: a count gate alone leaves the
 * lock and the server's own verifier free to answer differently on bytes an
 * adopter can put on the wire. Each vector is signed with the dev key in
 * ../config/dev_unlock_key.pem and sits in the KAT window (exp=1750000900,
 * NOW_FRESH), so the parse is the only gate left to answer.
 *
 * The trailing-delimiter vector is the one worth reading twice. It is the
 * canonical six-field message with ONE '|' appended, and it is the shape a
 * count gate written in Ruby does not see: String#split("|") drops trailing
 * empty fields, so seven segments read back as six. The lock refuses it here,
 * and crosscheck_grammar.rb runs the same bytes through both Ruby readers.
 *
 * The rest are the charsets: an empty field, an `iat` that is not a number, an
 * `exp` spelled with a sign or overflowing uint64, and a jti in the wrong
 * case. Each is a spelling a permissive integer or string parse admits and
 * this verifier must not.
 */
static void test_field_content_boundary(void)
{
    int result;

    /* Six fields with ONE delimiter appended — seven segments, the last empty. */
    static const char TOKEN_TRAILING_DELIM[] =
        "kiosk-rental-v1|SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899|"
        "."
        "j6zKGe-EB1o44dW1TQqGTNE4Z6CWkyPP9SZbzTeHu2ic8xiThaQwzFA3fYY2jPM7RAGbhF2L_bYGKaz5GOCNAg";

    /* Six fields, but reservation_id has no bytes. */
    static const char TOKEN_EMPTY_RESV[] =
        "kiosk-rental-v1|SK-001||1750000000|1750000900|aabbccddeeff00112233445566778899"
        "."
        "7dtVID5zxAiS7re1uIs-NVnySv3-teND1JZih5mh9Ja8bpu-3z1deE5s20l4GoMsY9JF5iJMRTtMM0_UxOKIAQ";

    /* iat is not a decimal integer at all. */
    static const char TOKEN_IAT_JUNK[] =
        "kiosk-rental-v1|SK-001|resv-1|abc|1750000900|aabbccddeeff00112233445566778899"
        "."
        "DO1cGV7SQsOEwhzVQ5J_AOUV-URLPn2utbm51QcNn9k8D1DEDfSPHmCJLWToHHX6gBiDlcEuuQAG396L5z75Ag";

    /* exp carries a leading '+' — an integer to Ruby's Integer(), not to us. */
    static const char TOKEN_EXP_SIGNED[] =
        "kiosk-rental-v1|SK-001|resv-1|1750000000|+1750000900|aabbccddeeff00112233445566778899"
        "."
        "Km-69RjggQc_JWDpKdqu8EAj4x2afPWTRHtogDGxIGx_hOYdXf2nXVDm4ybmT5IPiTA3U1wb39VKm2BijfA2Aw";

    /* exp is twenty digits and past UINT64_MAX — a far-future expiry if honoured. */
    static const char TOKEN_EXP_OVERFLOW[] =
        "kiosk-rental-v1|SK-001|resv-1|1750000000|99999999999999999999|aabbccddeeff00112233445566778899"
        "."
        "Wm-_DEGBu1eURAfYDAUig-kO1PEdQuyTEmWGQ2d3d9QPuerhwHAuO0xSTLG0m7OrJUwSK_7u2SSn-WtlRyI3CA";

    /* jti in uppercase hex — 32 characters, wrong alphabet. */
    static const char TOKEN_JTI_UPPER[] =
        "kiosk-rental-v1|SK-001|resv-1|1750000000|1750000900|AABBCCDDEEFF00112233445566778899"
        "."
        "1olaodhhNIl_KdnFqPGCM6pRyRiameicL3qtBQLJ_cky8nm8VS51SetXoiHfvvsIL4KstqrV3HRFwrJ2XGC-DQ";

    printf("\n[9] Field-content boundary, valid signature on every vector → all 0\n");

    result = skooti_verify_token(SKOOTI_PUBKEY, TOKEN_TRAILING_DELIM, SCOOTER_CODE, NOW_FRESH);
    printf("  six fields plus one trailing delimiter → result: %d\n", result);
    check(result == 0, "trailing delimiter (seven segments, last empty) → 0");

    result = skooti_verify_token(SKOOTI_PUBKEY, TOKEN_EMPTY_RESV, SCOOTER_CODE, NOW_FRESH);
    printf("  empty reservation_id → result: %d\n", result);
    check(result == 0, "empty field → 0");

    result = skooti_verify_token(SKOOTI_PUBKEY, TOKEN_IAT_JUNK, SCOOTER_CODE, NOW_FRESH);
    printf("  iat = \"abc\" → result: %d\n", result);
    check(result == 0, "iat that is not a number → 0");

    result = skooti_verify_token(SKOOTI_PUBKEY, TOKEN_EXP_SIGNED, SCOOTER_CODE, NOW_FRESH);
    printf("  exp = \"+1750000900\" → result: %d\n", result);
    check(result == 0, "exp with a leading plus → 0");

    result = skooti_verify_token(SKOOTI_PUBKEY, TOKEN_EXP_OVERFLOW, SCOOTER_CODE, NOW_FRESH);
    printf("  exp = twenty digits past UINT64_MAX → result: %d\n", result);
    check(result == 0, "exp past UINT64_MAX → 0");

    result = skooti_verify_token(SKOOTI_PUBKEY, TOKEN_JTI_UPPER, SCOOTER_CODE, NOW_FRESH);
    printf("  jti in uppercase hex → result: %d\n", result);
    check(result == 0, "jti in the wrong alphabet → 0");

    /* And the jti the replay store would be keyed on is parsed under the same
     * contract: the good token yields its jti, the trailing-delimiter one does
     * not, so no path reaches jti_store with bytes the verifier refused. */
    {
        char jti[JTI_MAX_LEN];
        result = skooti_parse_jti(WIRE_TOKEN, jti, sizeof(jti));
        check(result == 1 && strcmp(jti, "aabbccddeeff00112233445566778899") == 0,
              "skooti_parse_jti: six-field token → the jti");
        result = skooti_parse_jti(TOKEN_TRAILING_DELIM, jti, sizeof(jti));
        check(result == 0, "skooti_parse_jti: trailing delimiter → 0");
        result = skooti_parse_jti(TOKEN_JTI_UPPER, jti, sizeof(jti));
        check(result == 0, "skooti_parse_jti: jti in the wrong alphabet → 0");
    }
}

/*
 * Test 10 — signature ENCODING: one signature, one spelling
 *
 * Five respellings of the known-answer token's signature field, every one of
 * them a refusal. The first three carry the SAME valid 64 bytes as the token
 * above and differ only in how those bytes are written down; the last two are
 * the neighbouring lengths, which decode to 63 and 65 bytes and so are not a
 * signature at all.
 *
 * The three that matter divide by WHICH reader would otherwise have taken
 * them. `=` padding and the standard alphabet's `+` are what
 * Base64.urlsafe_decode64 accepts on the Ruby side without a charset gate in
 * front of it. The non-canonical final character is the other direction: Ruby
 * decodes strictly and refuses it, and it is the C decoder that has to be told
 * — of the sixteen strings that decode to one signature, one is canonical and
 * the other fifteen are refused here.
 */
static void test_sig_encoding(void)
{
    int result;
    printf("\n[10] Signature encoding and scalar range: padding, alphabet, canonical tail, S < L\n");

    /* 86 unpadded characters is the canonical width; padding takes it to 88,
     * which is exactly the early length guard, so length is not what answers. */
    result = skooti_verify_token(SKOOTI_PUBKEY, KAT_MSG "." KAT_SIG "==",
                                 SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "signature padded to 88 with '=' → 0");

    /* The same bytes in the STANDARD base64 alphabet: this signature's three
     * '-' characters spelled '+'. */
    result = skooti_verify_token(
        SKOOTI_PUBKEY,
        KAT_MSG "."
        "SDKHoyU3zzqvpVCwOcKf75EMJCyNKaxuRbvY3HmuM+q++ZaMEdeSmBi40JgZyhvBuL4A15xlupYqlGMfCnROCg",
        SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "signature in the standard base64 alphabet → 0");

    /* 86 characters carry 516 bits and the signature is 512, so the final
     * character has four bits that decode to nothing. Canonical leaves them
     * zero; this token sets them, decodes to the identical 64 bytes, and is a
     * different string on the wire — 'g' (value 32) becomes 'v' (value 47). */
    result = skooti_verify_token(
        SKOOTI_PUBKEY,
        KAT_MSG "."
        "SDKHoyU3zzqvpVCwOcKf75EMJCyNKaxuRbvY3HmuM-q--ZaMEdeSmBi40JgZyhvBuL4A15xlupYqlGMfCnROCv",
        SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "signature with a non-canonical final character → 0");

    /* 85 characters decode to 63 bytes, 87 to 65 — neither is a signature. */
    result = skooti_verify_token(
        SKOOTI_PUBKEY,
        KAT_MSG "."
        "SDKHoyU3zzqvpVCwOcKf75EMJCyNKaxuRbvY3HmuM-q--ZaMEdeSmBi40JgZyhvBuL4A15xlupYqlGMfCnROC",
        SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "signature one character short → 0");

    result = skooti_verify_token(SKOOTI_PUBKEY, KAT_MSG "." KAT_SIG "A",
                                 SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "signature one character long → 0");

    /* The four cases below respell the SCALAR rather than the encoding, and
     * they are the reason verify.c carries its own canonicality check.
     *
     * A signature is R || S and RFC 8032 5.1.7 decodes S "in the range
     * 0 <= s < L". The vendored verifier bounds S only by `signature[63] &
     * 224` — S < 2^253 — and [L]B is the identity, so S + L satisfies the very
     * equation S does. Between L and 2^253 exactly one more multiple of L
     * fits, which is the whole of the window: S + 2L carries bits the coarse
     * bound already refuses. Both Ruby readers verify through OpenSSL, which
     * applies the range check, so before this the physical lock — the widest
     * reader of the three — took a token neither of them would.
     *
     * Same R, same message, same key, same 86-character width: what moved is
     * the one number the RFC puts a range on. */
    result = skooti_verify_token(
        SKOOTI_PUBKEY,
        KAT_MSG "."
        "SDKHoyU3zzqvpVCwOcKf75EMJCyNKaxuRbvY3HmuM-qrzYzpKzql8O5UyDv4w_rVuL4A15xlupYqlGMfCnROGg",
        SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "signature scalar moved up by the group order → 0");

    /* The bound itself. The range is half-open, so L is not a canonical
     * scalar; this pins which side of the boundary the lock holds. */
    result = skooti_verify_token(
        SKOOTI_PUBKEY,
        KAT_MSG "."
        "SDKHoyU3zzqvpVCwOcKf75EMJCyNKaxuRbvY3HmuM-rt0_VcGmMSWNac96Le-d4UAAAAAAAAAAAAAAAAAAAAEA",
        SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "signature scalar equal to the group order → 0");

    /* L - 1 IS a canonical scalar: it passes the new check and is then refused
     * by the verification equation, which is the case that separates "the
     * canonicality check works" from "the canonicality check refuses
     * everything near L". */
    result = skooti_verify_token(
        SKOOTI_PUBKEY,
        KAT_MSG "."
        "SDKHoyU3zzqvpVCwOcKf75EMJCyNKaxuRbvY3HmuM-rs0_VcGmMSWNac96Le-d4UAAAAAAAAAAAAAAAAAAAAEA",
        SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "signature scalar one below the group order → 0");

    /* S + 2L, refused by the vendored verifier's own coarse bound. Kept so a
     * regression that deleted the canonicality check would still leave this
     * one passing — which is exactly why it is not evidence on its own. */
    result = skooti_verify_token(
        SKOOTI_PUBKEY,
        KAT_MSG "."
        "SDKHoyU3zzqvpVCwOcKf75EMJCyNKaxuRbvY3HmuM-qYoYJGRp23SMXxv97WvdnquL4A15xlupYqlGMfCnROKg",
        SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "signature scalar moved up by two group orders → 0");

    /* And the control: the canonical signature still verifies, so none of the
     * above is a check that simply refuses this message. */
    result = skooti_verify_token(SKOOTI_PUBKEY, WIRE_TOKEN, SCOOTER_CODE, NOW_FRESH);
    check(result == 1, "the canonical signature still verifies → 1");
}

/*
 * Test 11 — skooti_verify_wire: the byte buffer, NUL included
 *
 * This is the entry point the sketch calls with the BLE write's own size. The
 * verifier below it reads a `const char *` and ends at the first NUL, so a
 * write carrying one would be verified as the prefix before it while the rest
 * of the writer's bytes went unread; the grammar admits no NUL in a wire
 * token, so the whole buffer is refused.
 */
static void test_wire_bytes(void)
{
    static const char nul_inside[] =
        "kiosk-rental-v1|SK-001|resv\0-1|1750000000|1750000900|aabbccddeeff00112233445566778899"
        "." KAT_SIG;
    char trailing[sizeof(WIRE_TOKEN) + 1];
    int  result;

    printf("\n[11] skooti_verify_wire: the write's own byte count → expect 0 on any NUL\n");

    result = skooti_verify_wire(SKOOTI_PUBKEY, WIRE_TOKEN, strlen(WIRE_TOKEN),
                                SCOOTER_CODE, NOW_FRESH);
    check(result == 1, "wire: the known-answer token at its own length → 1");

    /* sizeof - 1 drops the terminator the compiler appends; the NUL this
     * buffer is testing is the one written INTO the reservation id. */
    result = skooti_verify_wire(SKOOTI_PUBKEY, nul_inside, sizeof(nul_inside) - 1,
                                SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "wire: a NUL inside reservation_id → 0");

    memcpy(trailing, WIRE_TOKEN, sizeof(WIRE_TOKEN)); /* copies the terminator */
    result = skooti_verify_wire(SKOOTI_PUBKEY, trailing, sizeof(WIRE_TOKEN),
                                SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "wire: a NUL appended to a valid token → 0");

    result = skooti_verify_wire(SKOOTI_PUBKEY, WIRE_TOKEN, 0, SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "wire: a zero-length write → 0");
}

/*
 * Test 11b — skooti_verify_wire's token_len BOUNDS the verification
 *
 * This is the one property the shared grammar vector set structurally cannot
 * reach: crosscheck_grammar.rb hands the helper a file and the helper passes
 * the file's own size, so every vector there carries an HONEST length. The
 * question here is what happens when it does not, and it is a C-level question
 * because a wire token cannot express it.
 *
 * A length used only for the cap and the NUL scan, with the parse then run
 * over a `const char *` to whatever terminator it finds, gives two answers
 * nobody asks for: a caller reporting a shorter length than the buffer holds
 * gets the LONGER token verified, which is an accept rather than a refusal,
 * and a caller whose buffer is not terminated at token_len has it read past.
 * Neither is reachable from the board, where std::string::c_str() terminates
 * at size(); both are reachable from the socket or ring-buffer caller the
 * header offers this function to. The arms below are what hold the count to
 * the parse.
 *
 * The last arm is the one `make test-asan` earns its place on: an
 * unterminated heap allocation of exactly the token's length. A read one byte
 * past it is a heap-buffer-overflow ASan reports.
 */
static void test_wire_length_bound(void)
{
    size_t honest = strlen(WIRE_TOKEN);
    char  *heap;
    char   trailing[sizeof(WIRE_TOKEN) + 8];
    char   jti[40];
    int    result;

    printf("\n[11b] skooti_verify_wire: token_len bounds the parse → expect 0 on a short length\n");

    result = skooti_verify_wire(SKOOTI_PUBKEY, WIRE_TOKEN, honest, SCOOTER_CODE, NOW_FRESH);
    check(result == 1, "bound: the known-answer token at its honest length → 1");

    result = skooti_verify_wire(SKOOTI_PUBKEY, WIRE_TOKEN, 10, SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "bound: the same buffer declared as 10 bytes → 0");

    result = skooti_verify_wire(SKOOTI_PUBKEY, WIRE_TOKEN, 1, SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "bound: the same buffer declared as 1 byte → 0");

    result = skooti_verify_wire(SKOOTI_PUBKEY, WIRE_TOKEN, honest - 1,
                                SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "bound: one byte short of honest (signature truncated) → 0");

    /* Bytes AFTER the declared length, still inside a terminated buffer: the
     * token is what the caller declared, and the trailing bytes — which no
     * signature covers — are not part of it. */
    memcpy(trailing, WIRE_TOKEN, honest);
    memcpy(trailing + honest, "GARBAGE", 8); /* copies its terminator */
    result = skooti_verify_wire(SKOOTI_PUBKEY, trailing, honest, SCOOTER_CODE, NOW_FRESH);
    check(result == 1, "bound: trailing bytes past token_len are not verified → 1");

    /* An UNTERMINATED buffer of exactly token_len bytes. Under ASan a read one
     * past the allocation is a heap-buffer-overflow; this arm is why
     * `make test-asan` is run on this file. */
    heap = (char *)malloc(honest);
    check(heap != NULL, "bound: unterminated heap buffer allocated");
    if (heap) {
        memcpy(heap, WIRE_TOKEN, honest);
        result = skooti_verify_wire(SKOOTI_PUBKEY, heap, honest, SCOOTER_CODE, NOW_FRESH);
        check(result == 1, "bound: an unterminated buffer at its own length → 1, no read past it");

        result = skooti_parse_jti_n(heap, honest, jti, sizeof(jti));
        check(result == 1 && strcmp(jti, "aabbccddeeff00112233445566778899") == 0,
              "bound: skooti_parse_jti_n on the same unterminated buffer → the jti");
        free(heap);
    }

    result = skooti_parse_jti_n(WIRE_TOKEN, 10, jti, sizeof(jti));
    check(result == 0, "bound: skooti_parse_jti_n with a short length → 0");
}

/*
 * Test 12 — the freshness boundary: the window is now < exp
 *
 * Test 2 above proves a token past its expiry is refused. This one pins the
 * instant itself, because that is the second the three readers of this token
 * have to answer identically and the only way to say which second it is.
 */
static void test_expiry_boundary(void)
{
    int result;
    printf("\n[12] Freshness boundary at exp=1750000900 → expect 0 at exp, 1 one second before\n");

    result = skooti_verify_token(SKOOTI_PUBKEY, WIRE_TOKEN, SCOOTER_CODE, NOW_AT_EXP);
    check(result == 0, "now == exp → 0 (the window is now < exp)");

    result = skooti_verify_token(SKOOTI_PUBKEY, WIRE_TOKEN, SCOOTER_CODE, NOW_LAST);
    check(result == 1, "now == exp - 1 → 1 (last live second)");
}

/*
 * Test 13 — public-key encoding: RFC 8032 5.1.3 steps 1 and 3
 *
 * The vendored library applies neither. It masks bit 255 off the key and
 * reduces whatever is left instead of refusing a y at or above the field
 * prime (step 1), and it compares a recovered x of 0 against the requested
 * sign bit instead of refusing that pair (step 3). So one point has several
 * byte spellings it accepts.
 *
 * That is not a paper deviation, and IDENTITY_SIG below is why. A signature
 * verifies under the identity point whatever the message says: the equation
 * is [S]B = R + [k]A, and A = identity collapses it to [S]B = R, which
 * R = [1]B and S = 1 satisfy. Anyone can write those 64 bytes down. So each
 * accepted spelling of the identity is a public key under which THIS lock
 * would open on a token nobody signed, and the library on its own takes all
 * three: the canonical `01 00..00`, the same y written as p + 1, and
 * `01 00..00 80`, which is the canonical y with the sign bit set.
 *
 * skooti_pubkey_is_canonical does NOT refuse the canonical identity, and that
 * is deliberate: RFC 8032 does not require a verifier to reject small-order or
 * identity keys, so the predicate answers the RFC's question and answers 1 for
 * it. What this predicate pins is that the two SPELLINGS the RFC forbids are
 * gone, so a fleet that blocks a key by its bytes blocks it once and for all.
 * The verify PATH, however, refuses the canonical identity too — see test 15,
 * which pins skooti_pubkey_is_low_order and the forgery it closes — so the
 * end-to-end pair below now answers 0 for the canonical spelling as well.
 *
 * The first half asserts the predicate directly, because most of its domain
 * cannot be reached through a token: a key that is merely wrong refuses every
 * signature anyway, so an end-to-end call cannot tell "refused the key" from
 * "refused the signature". The second half is the end-to-end pair, on the one
 * input where the two answers differ.
 */
static void test_pubkey_canonical(void)
{
    uint8_t key[32];
    int     result;
    int     i;

    /* R = [1]B (the base-point encoding) || S = 1, little-endian. */
#define IDENTITY_SIG \
    "WGZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmYBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    printf("\n[13] Public-key encoding: y < p, and x = 0 only with the sign bit clear\n");

    /* The provisioned key itself — the check must not refuse the real one. */
    check(skooti_pubkey_is_canonical(SKOOTI_PUBKEY) == 1,
          "the provisioned skooti public key is canonical → 1");

    check(skooti_pubkey_is_canonical(NULL) == 0, "NULL public key → 0");

    /* y = 0 and y = p - 1 are the ends of the legal range; both are canonical,
     * which separates "the range check works" from "it refuses the edges". */
    memset(key, 0, 32);
    check(skooti_pubkey_is_canonical(key) == 1, "y = 0 → 1 (bottom of the range)");

    key[0] = 0xec; for (i = 1; i < 31; i++) key[i] = 0xff; key[31] = 0x7f;
    check(skooti_pubkey_is_canonical(key) == 1, "y = p - 1 → 1 (top of the range)");

    /* Step 1: y at or above p. p itself, p + 1, and every bit set (p + 18 with
     * the sign bit on) — the three that a masking decoder silently reduces. */
    key[0] = 0xed; for (i = 1; i < 31; i++) key[i] = 0xff; key[31] = 0x7f;
    check(skooti_pubkey_is_canonical(key) == 0, "y = p → 0 (same point as y = 0)");

    key[0] = 0xee; for (i = 1; i < 31; i++) key[i] = 0xff; key[31] = 0x7f;
    check(skooti_pubkey_is_canonical(key) == 0, "y = p + 1 → 0 (same point as y = 1)");

    memset(key, 0xff, 32);
    check(skooti_pubkey_is_canonical(key) == 0, "every bit set → 0 (y = p + 18)");

    /* Step 3: x = 0 is exactly y = 1 and y = p - 1, and each is legal with the
     * sign bit CLEAR and refused with it SET. Four assertions, because a check
     * that refused both signs would break the identity encoding the RFC
     * allows. */
    memset(key, 0, 32); key[0] = 0x01;
    check(skooti_pubkey_is_canonical(key) == 1, "y = 1, sign clear → 1 (identity, legal)");

    key[31] = 0x80;
    check(skooti_pubkey_is_canonical(key) == 0, "y = 1, sign set → 0 (x = 0 with x_0 = 1)");

    key[0] = 0xec; for (i = 1; i < 31; i++) key[i] = 0xff; key[31] = 0x7f;
    check(skooti_pubkey_is_canonical(key) == 1, "y = p - 1, sign clear → 1 (order-2 point)");

    key[31] = 0xff;
    check(skooti_pubkey_is_canonical(key) == 0, "y = p - 1, sign set → 0 (x = 0 with x_0 = 1)");

    /* End to end. IDENTITY_SIG is a signature nobody had to hold a key to
     * write, and the three spellings below all decode to the point it verifies
     * under. All three now answer 0: the two the RFC forbids (step 1 / step 3)
     * are turned away by the canonicality check, and the first — the canonical
     * identity the RFC permits — is turned away by the low-order refusal in the
     * verify path (test 15). Before that refusal existed the first answered 1,
     * which is the forgery this test now pins closed. */
    memset(key, 0, 32); key[0] = 0x01;
    result = skooti_verify_token(key, KAT_MSG "." IDENTITY_SIG, SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "identity key, canonical spelling → 0 (low-order key refused by verify)");

    key[0] = 0xee; for (i = 1; i < 31; i++) key[i] = 0xff; key[31] = 0x7f;
    result = skooti_verify_token(key, KAT_MSG "." IDENTITY_SIG, SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "identity key spelled y = p + 1 → 0 (the library on its own answers 1)");

    memset(key, 0, 32); key[0] = 0x01; key[31] = 0x80;
    result = skooti_verify_token(key, KAT_MSG "." IDENTITY_SIG, SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "identity key with the sign bit set → 0 (the library on its own answers 1)");

    /* And the control: the real key and the real token are untouched by all of
     * the above. */
    result = skooti_verify_token(SKOOTI_PUBKEY, WIRE_TOKEN, SCOOTER_CODE, NOW_FRESH);
    check(result == 1, "the provisioned key still verifies the known-answer token → 1");

#undef IDENTITY_SIG
}

/*
 * Test 15 — low-order public keys: the forgery, refused
 *
 * A low-order public key is a CANONICAL encoding — skooti_pubkey_is_canonical
 * answers 1 for it, correctly, because RFC 8032 does not require the refusal —
 * yet under it a signature nobody produced verifies: R = [1]B, S = 1, with the
 * jti ground so the reduced hash is a multiple of the key's order and [h]A
 * vanishes. skooti_pubkey_is_low_order refuses the eight canonical small-order
 * encodings, and the verify path calls it, so the forgery is turned away.
 *
 * ORDER8_PUBKEY is the order-8 point encoded c7176a70…03fa; FORGED_ORDER8_TOKEN
 * carries R = [1]B, S = 1 over a message whose jti (…0013) makes the reduced
 * hash a multiple of 8. A monotone counter found that jti on the twentieth try
 * (the mean over keys is eight).
 */
static void test_pubkey_low_order(void)
{
    uint8_t key[32];
    int     result;
    int     i;

    /* order-8 point, canonical encoding c7176a70...03fa */
    static const uint8_t ORDER8_PUBKEY[32] = {
        0xc7, 0x17, 0x6a, 0x70, 0x3d, 0x4d, 0xd8, 0x4f,
        0xba, 0x3c, 0x0b, 0x76, 0x0d, 0x10, 0x67, 0x0f,
        0x2a, 0x20, 0x53, 0xfa, 0x2c, 0x39, 0xcc, 0xc6,
        0x4e, 0xc7, 0xfd, 0x77, 0x92, 0xac, 0x03, 0xfa
    };
    /* message . base64url(R = [1]B || S = 1) */
#define FORGED_ORDER8_TOKEN \
    "kiosk-rental-v1|SK-001|resv-1|1750000000|1750000900|00000000000000000000000000000013." \
    "WGZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmYBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    printf("\n[15] Low-order public keys: the K-1617 forgery, refused\n");

    /* The order-8 key IS canonical — that is the whole trap. */
    check(skooti_pubkey_is_canonical(ORDER8_PUBKEY) == 1,
          "order-8 key is canonical → 1 (RFC 8032 does not refuse it)");

    /* skooti_pubkey_is_low_order flags the eight small-order encodings. */
    check(skooti_pubkey_is_low_order(ORDER8_PUBKEY) == 1, "order-8 key is low-order → 1");
    check(skooti_pubkey_is_low_order(SKOOTI_PUBKEY) == 0,
          "the provisioned key is not low-order → 0");
    check(skooti_pubkey_is_low_order(NULL) == 0, "NULL key → 0");

    /* The all-zero (uninitialised) key field is an order-4 point — the accident
     * that needs no attacker at all. */
    memset(key, 0, 32);
    check(skooti_pubkey_is_low_order(key) == 1,
          "all-zero key is low-order → 1 (order-4; the uninitialised-field accident)");

    /* identity (order 1) and the order-2 point are low-order too. */
    memset(key, 0, 32); key[0] = 0x01;
    check(skooti_pubkey_is_low_order(key) == 1, "identity key is low-order → 1");
    key[0] = 0xec; for (i = 1; i < 31; i++) key[i] = 0xff; key[31] = 0x7f;
    check(skooti_pubkey_is_low_order(key) == 1, "order-2 key is low-order → 1");

    /* THE FORGERY, end to end. Before the low-order refusal both answered 1. */
    result = skooti_verify_token(ORDER8_PUBKEY, FORGED_ORDER8_TOKEN, SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "order-8 forged token via skooti_verify_token → 0 (K-1617 closed)");

    result = skooti_verify_wire(ORDER8_PUBKEY, FORGED_ORDER8_TOKEN,
                                strlen(FORGED_ORDER8_TOKEN), SCOOTER_CODE, NOW_FRESH);
    check(result == 0, "order-8 forged token via skooti_verify_wire → 0 (K-1617 closed)");

#undef FORGED_ORDER8_TOKEN
}

/*
 * Test 14 — jti_store: insert, replay detection, expiry pruning, table-full eviction
 */
static void test_jti_store(void)
{
    int r;

    printf("\n[14] jti_store: insert, replay, prune, table-full eviction\n");

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
    test_field_content_boundary();
    test_sig_encoding();
    test_wire_bytes();
    test_wire_length_bound();
    test_expiry_boundary();
    test_pubkey_canonical();
    test_jti_store();
    test_pubkey_low_order();

    printf("\n=== Results: %d passed, %d failed ===\n", g_pass, g_fail);

    if (g_fail > 0) {
        printf("FAIL\n");
        return 1;
    }
    printf("ALL PASS\n");
    return 0;
}
