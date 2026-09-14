/*
 * verify.c — skooti offline rental-token verification (offline Ed25519)
 *
 * Portable C99.  No BLE, Arduino, or platform-specific dependencies.
 * Compiles on host (clang/gcc) and ESP32-C3 toolchain.
 *
 * See verify.h for the full token wire-format and clock documentation.
 *
 * Token wire format:
 *   message = "kiosk-rental-v1|<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>"
 *   wire    = "<message>.<base64url(sig)>"
 *
 * Field indices (0-based) — EXACTLY six, no more and no fewer:
 *   [0] domain tag      "kiosk-rental-v1"
 *   [1] scooter_code    e.g. "SK-001"
 *   [2] reservation_id  e.g. "resv-1"
 *   [3] iat             1-20 ASCII digits
 *   [4] exp             1-20 ASCII digits
 *   [5] jti             32 lowercase hex chars
 *
 * The full grammar this file implements — every field's charset, the
 * delimiter rule and the wire-length cap — is written out in
 * ../RENTAL_TOKEN.md, which is the canonical page for this token, and the
 * same grammar is implemented by RentalTokenIssuer.verify and by
 * script/lock_sim.rb. `make crosscheck` runs one shared vector set
 * (token_vectors.rb) through all three and fails on any disagreement.
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

/*
 * ct_le32_lt — is the 256-bit little-endian number at `a` strictly below the
 * one at `b`?  Returns 1 or 0, and the comparison is STRICT: equal answers 0.
 *
 * Both RFC 8032 range rules this file implements are this one question asked
 * of a different constant — the signature's scalar against the group order,
 * the public key's y coordinate against the field prime — so it is written
 * once.
 *
 * CONSTANT TIME. Neither operand is a secret: both arrive from outside and one
 * of them is a compile-time constant. A verifier that answers in a
 * data-dependent time still tells a caller WHICH check refused it, so this one
 * does not branch on the bytes: all 32 positions are always read, in a fixed
 * order, the comparison state is carried in arithmetic rather than in control
 * flow, and there is no early return and no memory access indexed by the
 * input.
 *
 * `lt` and `gt` latch the verdict of the most significant byte position at
 * which the two differ. `undecided` is 1 until one of them latches, and masks
 * every later position out arithmetically — which is what replaces the `break`
 * a readable version would have.
 */
static int ct_le32_lt(const uint8_t a[32], const uint8_t b[32])
{
    uint32_t lt = 0;
    uint32_t gt = 0;
    int i;

    for (i = 31; i >= 0; i--) {
        uint32_t av = (uint32_t)a[i];
        uint32_t bv = (uint32_t)b[i];
        /* Unsigned wraparound sets bit 31 exactly when the left side is the
         * smaller byte; both operands are below 256, so this is defined. */
        uint32_t a_lt_b = ((av - bv) >> 31) & 1u;
        uint32_t b_lt_a = ((bv - av) >> 31) & 1u;
        uint32_t undecided = (lt | gt) ^ 1u;

        lt |= undecided & a_lt_b;
        gt |= undecided & b_lt_a;
    }

    /* Equal all the way down leaves both flags 0, which is the 0 answer. */
    return (int)lt;
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
 * Returns 1 on success, 0 if any character is invalid, if the output would
 * exceed dst_cap (overflow guard — rejects oversized input), or if the input
 * is not the CANONICAL encoding of the bytes it decodes to (see below).
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

    /* Canonical tail. The trailing characters that do not complete a byte
     * carry leftover bits, and a canonical encoding leaves those bits zero.
     * Sixteen spellings of one 64-byte Ed25519 signature differ only there —
     * the 86-character encoding has four such bits — so a decoder that drops
     * them lets sixteen distinct wire tokens carry one signature. The two Ruby
     * readers decode strictly and admit only the one, and where readers of a
     * credential differ the WIDEST decides what a fleet accepts, so this is
     * the narrow reading: a signature has exactly one encoding.
     *
     * `bits` here is the leftover count: 0, 4 or 2 for an input length of 4n,
     * 4n+2 or 4n+3. A value of 6 means the length is 4n+1, which is not a
     * base64 length at all and encodes nothing. */
    if (bits >= 6) return 0;
    if (bits > 0 && (accum & ((1u << bits) - 1u)) != 0) return 0;

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
 * Opaque-field charset — the RFC 3986 unreserved set, `A-Za-z0-9-._~`.
 *
 * scooter_code and reservation_id are the two fields whose CONTENT this lock
 * does not otherwise interpret, and an uninterpreted field is where three
 * independent readers pull apart: "any bytes but the delimiter" is a domain of
 * 254 values per position that nobody can enumerate, so a claim about it
 * cannot be checked and every reader ends up with its own answer. Sixty-six
 * characters can be enumerated, and ../RENTAL_TOKEN.md's charset rule is held
 * by a vector for every one of the 256 byte values rather than by a sentence.
 *
 * The set is not arbitrary: it is exactly the characters that survive the App
 * Clip launch URL unchanged, it contains every character a canonical uuid and
 * an `SK-###` fleet code are spelled with, and it excludes the delimiter and
 * the NUL byte, so those two prohibitions are consequences of one positive
 * rule rather than separate negatives.
 *
 * Returns 1 when s[0..len) is non-empty and drawn from that set, 0 otherwise.
 * -------------------------------------------------------------------------- */

static int is_unreserved(const char *s, size_t len)
{
    size_t i;

    if (len == 0) return 0;

    for (i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c >= 'A' && c <= 'Z') continue;
        if (c >= 'a' && c <= 'z') continue;
        if (c >= '0' && c <= '9') continue;
        if (c == '-' || c == '.' || c == '_' || c == '~') continue;
        return 0;
    }

    return 1;
}

/* --------------------------------------------------------------------------
 * jti charset — exactly 32 lowercase hex characters.
 *
 * The issuer mints the jti as SecureRandom.hex(16), so 32 lowercase hex is
 * what a genuine token carries and anything else is a message this lock was
 * never meant to see. Checking it here rather than trusting it matters for one
 * concrete reason: the jti is the KEY the replay store is written under, and
 * jti_store's own buffer is JTI_MAX_LEN. A verifier that returns 1 on a jti the
 * store then refuses splits the lock's answer in two — verify says yes, the
 * unlock path says no — and a lock that answers a question two ways is a lock
 * whose behaviour nobody can state.
 * Returns 1 when s[0..len) is 32 characters drawn from [0-9a-f], 0 otherwise.
 * -------------------------------------------------------------------------- */

static int is_jti(const char *s, size_t len)
{
    size_t i;

    if (len != 32) return 0;

    for (i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        int digit = (c >= '0' && c <= '9');
        int lower = (c >= 'a' && c <= 'f');
        if (!digit && !lower) return 0;
    }

    return 1;
}

/* --------------------------------------------------------------------------
 * Canonical Ed25519 scalar — RFC 8032 5.1.7 step 1, the half the vendored
 * verifier does not implement.
 *
 * A signature is R || S, and S is a scalar: RFC 8032 decodes it "in the range
 * 0 <= s < L", L = 2^252 + 27742317777372353535851937790883648493 being the
 * order of the prime-order subgroup, and calls a signature whose S is outside
 * that range invalid. ed25519/verify.c bounds S only by `signature[63] & 224`,
 * which refuses S >= 2^253 and nothing finer. Between L and 2^253 there is
 * room for exactly one more multiple of L, and [L]B is the identity, so S + L
 * satisfies the very equation S does: a second 64-byte signature over the same
 * message, verifying under the same key.
 *
 * That matters here because this lock is one of THREE readers of a rental
 * token and the other two verify through OpenSSL, which does apply the range
 * check. Without this the physical lock — the widest reader, and the one
 * nothing downstream can correct — would take a token both Ruby readers
 * refuse. ../RENTAL_TOKEN.md states the rule for all three.
 *
 * CONSTANT TIME. S arrives on the wire and is not a secret, but a verifier
 * that answers in a data-dependent time tells a caller WHICH check refused it,
 * so this one does not branch on the bytes: all 32 byte positions are always
 * read, in a fixed order, the comparison state is carried in arithmetic rather
 * than in control flow, and there is no early return and no memory access
 * indexed by the input.
 *
 * Returns 1 when the 32 little-endian bytes at s are a scalar below L, 0
 * otherwise. S == L is NOT canonical: the range is half-open.
 * -------------------------------------------------------------------------- */

/* L, the group order, little-endian — the same constant ed25519/sc.h names. */
static const uint8_t SC_ORDER_LE[32] = {
    0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
    0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10
};

static int ct_scalar_is_canonical(const uint8_t s[32])
{
    /* Strict, so s == L answers 0: the range the RFC gives is half-open. */
    return ct_le32_lt(s, SC_ORDER_LE);
}

/* --------------------------------------------------------------------------
 * Canonical Ed25519 public key — RFC 8032 5.1.3 steps 1 and 3, the other two
 * decode rules the vendored verifier does not implement.
 *
 * 5.1.3 reads the 32 bytes as a little-endian number, takes bit 255 as x_0
 * (the low bit of the x coordinate), clears it to get y, and FAILS when the
 * remaining y is at or above the field prime p = 2^255 - 19 (step 1) or when
 * the recovered x is 0 while x_0 is 1 (step 3). ed25519/ applies neither:
 * fe_frombytes masks bit 255 off and reduces whatever is left, and the sign
 * fixup compares a zero x against the requested sign instead of refusing that
 * pair. So one point has several accepted spellings.
 *
 * MEASURED against the shipped ed25519/ sources, with a signature that
 * verifies under the identity point — R = [1]B, S = 1, which satisfies
 * [S]B = R + [k]A for A = identity whatever the message is. All three of
 * `01 00..00` (y = 1, the canonical identity), `ee ff..ff 7f` (y = p + 1,
 * which reduces to 1) and `01 00..00 80` (y = 1 with x_0 set, which 5.1.3
 * step 3 refuses) decode to that same point, and ed25519_verify answers 1 for
 * every one of them. Only the first is a legal encoding.
 *
 * WHY IT IS CHECKED HERE rather than left as a stated limit. This lock is
 * given its key once at provisioning and never reads one off a token, so
 * nothing an attacker writes to THIS lock reaches either rule. But this file
 * is a reference an adopter copies, and an adopter's key may arrive from
 * somewhere this demo has no view of — a fleet message, a provisioning tag, a
 * config a server pushes. Two consequences travel with the extra spellings: a
 * key blocklist or a fleet ACL keyed on the 32 bytes has three names for one
 * key and blocks one of them, and a lock provisioned with a spelling the RFC
 * refuses is a lock whose identity no conforming implementation agrees on.
 * The check is 96 byte-comparisons against three constants, it leaves
 * ed25519/ a verbatim drop, and it fails closed.
 *
 * The x = 0 test needs no field arithmetic. The curve equation is
 * -x^2 + y^2 = 1 + d x^2 y^2, so x = 0 forces y^2 = 1 and, conversely, y = 1
 * or y = p - 1 forces x^2 (d + 1) = 0 and hence x = 0. Those two y values are
 * exactly the x = 0 encodings, and both are constants.
 * -------------------------------------------------------------------------- */

/* p = 2^255 - 19, the field prime, little-endian. */
static const uint8_t FE_PRIME_LE[32] = {
    0xed, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f
};

/* y = 1 — the identity point, and one of the two x = 0 encodings. */
static const uint8_t FE_ONE_LE[32] = {
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};

/* y = p - 1 — the order-2 point, and the other x = 0 encoding. */
static const uint8_t FE_PRIME_MINUS_ONE_LE[32] = {
    0xec, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f
};

int skooti_pubkey_is_canonical(const uint8_t pubkey[32])
{
    uint8_t  y[32];
    uint32_t x_0;
    uint32_t y_in_range;
    uint32_t x_is_zero;
    int      i;

    if (!pubkey) return 0;

    for (i = 0; i < 32; i++) y[i] = pubkey[i];
    x_0     = (uint32_t)(y[31] >> 7);
    y[31]  &= 0x7f;

    /* Step 1: y < p. */
    y_in_range = (uint32_t)ct_le32_lt(y, FE_PRIME_LE);

    /* Step 3: x = 0 with x_0 set is a refusal, and x = 0 is exactly y = 1 or
     * y = p - 1. Both comparisons always run — neither short-circuits. */
    x_is_zero = (uint32_t)ct_memeq(y, FE_ONE_LE, 32)
              | (uint32_t)ct_memeq(y, FE_PRIME_MINUS_ONE_LE, 32);

    return (int)(y_in_range & ((x_0 & x_is_zero) ^ 1u));
}

/* --------------------------------------------------------------------------
 * Small-order (low-order) public key — the eight canonical encodings of the
 * edwards25519 torsion subgroup, and a constant-time refusal of them.
 *
 * skooti_pubkey_is_canonical answers the RFC 8032 5.1.3 question — is this the
 * spelling the standard permits — and the standard does NOT require refusing a
 * low-order point, so a canonically-encoded order-1, -2, -4 or -8 point passes
 * it. That is not merely academic. With a low-order public key A a signature
 * nobody produced verifies: set R = [1]B (the base-point encoding) and S = 1,
 * so the check [S]B = R + [h]A reduces to [h]A = identity, which holds whenever
 * the reduced hash h is a multiple of ord(A). For A of order 8 a forger grinds
 * the one caller-visible field — the jti — until h is a multiple of 8, expected
 * eight tries; MEASURED, a monotone counter hit it on the twentieth and a mean
 * of eight over many keys. The identity point (order 1) needs no grinding at
 * all: [h]·identity is always identity.
 *
 * This lock is handed its key once at provisioning and never reads one off the
 * wire, so nothing an attacker WRITES to this lock reaches this rule. The rule
 * is here for the two ways a low-order key arrives without an attacker choosing
 * it: an adopter who copies this reference and whose key comes from a fleet
 * message, a provisioning tag or a server push that this file cannot audit, and
 * — the accident that needs no adversary at all — an uninitialised or truncated
 * key field, since the all-zero encoding is itself an order-4 point. Refusing
 * these keys is STRICTER than RFC 8032; it is the policy libsodium's
 * ge25519_has_small_order enforces, and for the same reason.
 *
 * The check is a fixed-table comparison — eight ct_memeq calls, all of which
 * run, no field arithmetic, no early exit, no data-dependent branch — so it
 * leaves ed25519/ a verbatim drop and adds no timing signal.
 * -------------------------------------------------------------------------- */

/* The eight CANONICAL encodings of the small-order points. Non-canonical
 * spellings of the same points (y >= p, or x = 0 with the sign bit set) are
 * already refused by skooti_pubkey_is_canonical, so this table need only carry
 * the spellings that pass it: identity (order 1), the order-2 point, both
 * order-4 encodings and all four order-8 encodings. */
static const uint8_t SMALL_ORDER_LE[8][32] = {
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80 },
    { 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    { 0x26, 0xe8, 0x95, 0x8f, 0xc2, 0xb2, 0x27, 0xb0,
      0x45, 0xc3, 0xf4, 0x89, 0xf2, 0xef, 0x98, 0xf0,
      0xd5, 0xdf, 0xac, 0x05, 0xd3, 0xc6, 0x33, 0x39,
      0xb1, 0x38, 0x02, 0x88, 0x6d, 0x53, 0xfc, 0x05 },
    { 0x26, 0xe8, 0x95, 0x8f, 0xc2, 0xb2, 0x27, 0xb0,
      0x45, 0xc3, 0xf4, 0x89, 0xf2, 0xef, 0x98, 0xf0,
      0xd5, 0xdf, 0xac, 0x05, 0xd3, 0xc6, 0x33, 0x39,
      0xb1, 0x38, 0x02, 0x88, 0x6d, 0x53, 0xfc, 0x85 },
    { 0xc7, 0x17, 0x6a, 0x70, 0x3d, 0x4d, 0xd8, 0x4f,
      0xba, 0x3c, 0x0b, 0x76, 0x0d, 0x10, 0x67, 0x0f,
      0x2a, 0x20, 0x53, 0xfa, 0x2c, 0x39, 0xcc, 0xc6,
      0x4e, 0xc7, 0xfd, 0x77, 0x92, 0xac, 0x03, 0x7a },
    { 0xc7, 0x17, 0x6a, 0x70, 0x3d, 0x4d, 0xd8, 0x4f,
      0xba, 0x3c, 0x0b, 0x76, 0x0d, 0x10, 0x67, 0x0f,
      0x2a, 0x20, 0x53, 0xfa, 0x2c, 0x39, 0xcc, 0xc6,
      0x4e, 0xc7, 0xfd, 0x77, 0x92, 0xac, 0x03, 0xfa },
    { 0xec, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
      0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
      0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
      0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f }
};

int skooti_pubkey_is_low_order(const uint8_t pubkey[32])
{
    uint32_t hit = 0;
    int      i;

    if (!pubkey) return 0;

    /* Every comparison runs; no short-circuit on the key bytes. */
    for (i = 0; i < 8; i++)
        hit |= (uint32_t)ct_memeq(pubkey, SMALL_ORDER_LE[i], 32);

    return (int)(hit & 1u);
}

/* --------------------------------------------------------------------------
 * verify_bounded — the whole verification, over EXACTLY token_len bytes.
 *
 * Every byte this function reads is in [token, token + token_len); it never
 * looks for a terminator and never reads one. That is what makes
 * skooti_verify_wire's length argument mean something: the wire entry point
 * hands its caller's own byte count straight down, so a buffer that is not
 * terminated at token_len is still never read past, and a length SHORTER than
 * the terminated content verifies the shorter token rather than the longer one
 * the caller did not declare. skooti_verify_token, whose contract is a
 * NUL-terminated string, measures the length itself and calls the same body,
 * so both entry points answer one question with one parser.
 * -------------------------------------------------------------------------- */

static int verify_bounded(const uint8_t pubkey[32],
                          const char   *token,
                          size_t        token_len,
                          const char   *my_scooter_code,
                          uint64_t      now_unix)
{
    size_t  dot_pos;
    size_t  msg_len;
    const char *sig_b64;
    size_t  sig_b64_len;

    /* Decoded sig buffer — Ed25519 sig is exactly 64 bytes */
    uint8_t sig[64];
    size_t  sig_len = 0;

    /* Message field parsing */
    const char *msg;
    /* Fields: [0]=domain_tag [1]=scooter_code [2]=reservation_id [3]=iat [4]=exp [5]=jti */
    const char *field_start[6];
    size_t      field_len[6];
    size_t      f;
    const char *p;
    size_t      remaining;
    int         field_idx;

    uint64_t iat_val;
    uint64_t exp_val;
    size_t   code_len;

    /* --- null guards --- */
    if (!pubkey || !token || !my_scooter_code) return 0;

    /* --- RFC 8032 5.1.3: the public key must be the canonical encoding of the
     * point it names. A provisioning-time property, checked on every verify
     * because this is the only place a caller of this file is guaranteed to
     * pass through: an adopter whose key arrives from a fleet message or a
     * provisioning tag gets the same refusal the sketch's baked key would.
     * See skooti_pubkey_is_canonical above for what the vendored decoder
     * takes without it. --- */
    if (!skooti_pubkey_is_canonical(pubkey)) return 0;

    /* --- A low-order public key is refused here too. It is a canonical
     * encoding, so the check above passes it, and under it a signature nobody
     * produced verifies — R = [1]B, S = 1, with a jti ground so [h]A vanishes.
     * That is stricter than RFC 8032 and matches libsodium; see
     * skooti_pubkey_is_low_order above for the reachability that earns it. --- */
    if (skooti_pubkey_is_low_order(pubkey)) return 0;

    /* --- token length cap --- */
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

    /* --- RFC 8032 5.1.7: the scalar half of the signature must be below the
     * group order. The vendored verifier only refuses S >= 2^253, which leaves
     * S + L verifying alongside S — one token with two wire spellings, and the
     * lock the only reader of the three that would take the second. See
     * ct_scalar_is_canonical above. --- */
    if (!ct_scalar_is_canonical(sig + 32)) return 0;

    /* --- Ed25519 verify: sig over msg bytes with pubkey --- */
    if (!ed25519_verify(sig, (const unsigned char *)msg, msg_len,
                        (const unsigned char *)pubkey))
        return 0;

    /* --- Parse the 6 pipe-delimited fields of the message ---
     * Fields: [0]=domain_tag [1]=scooter_code [2]=reservation_id [3]=iat [4]=exp [5]=jti
     * Every field is checked below, reservation_id included: the lock does not
     * ACT on it, and it is still held to a charset, because a field nobody
     * parses is a field every reader may read differently. We must confirm
     * exactly 6 fields are present, so a message with any other field count is
     * rejected.
     * FEWER than six is refused by the missing-'|' return in the loop below; MORE
     * than six by the last field refusing to contain one. Both halves are
     * load-bearing, and the second is the one that carries weight: extra pipes
     * arriving EARLY shift every field left, so field[4] stops being the expiry
     * and Gate 2 below reads a caller-supplied number instead. The issuer
     * refuses a '|' in either opaque input rather than signing one, so this is
     * the second of two answers to the same hazard.
     * The Ruby issuer's own verifier splits on '|' and demands 6; this is the
     * same answer, reached without allocating.
     */
    field_idx = 0;
    p         = msg;
    remaining = msg_len;

    for (f = 0; f < 6; f++) {
        const char *pipe;
        size_t      flen;

        if (f < 5) {
            /* Find the next '|' */
            size_t j;
            pipe = NULL;
            for (j = 0; j < remaining; j++) {
                if (p[j] == '|') { pipe = p + j; break; }
            }
            if (!pipe) return 0; /* fewer than 6 fields */
            flen = (size_t)(pipe - p);
        } else {
            /* Last field: everything remaining — and it may hold no further '|',
             * which is what refuses a message of MORE than 6 fields. */
            size_t j;
            for (j = 0; j < remaining; j++) {
                if (p[j] == '|') return 0; /* more than 6 fields */
            }
            flen = remaining;
        }

        if (flen == 0) return 0; /* empty field */

        field_start[field_idx] = p;
        field_len[field_idx]   = flen;
        field_idx++;

        if (f < 5) {
            p         = pipe + 1;
            remaining = msg_len - (size_t)(p - msg);
        }
    }
    (void)field_idx; /* suppress unused-variable warning */

    /* --- Gate 0: domain-separation tag — MUST be "kiosk-rental-v1" ---
     * Constant-time compare prevents timing oracle on the tag.
     * A token signed with this key but without the tag (or with a different
     * tag) is rejected here, before any other claim is acted on.
     */
    {
        static const char DOMAIN_TAG[] = "kiosk-rental-v1";
        size_t tag_len = sizeof(DOMAIN_TAG) - 1; /* strlen, no NUL */
        if (field_len[0] != tag_len) return 0;
        if (!ct_memeq(field_start[0], DOMAIN_TAG, tag_len)) return 0;
    }

    /* --- Gate 1: scooter_code (field[1]) must match this lock's code --- */
    code_len = strlen(my_scooter_code);
    if (field_len[1] != code_len) return 0;
    if (!ct_memeq(field_start[1], my_scooter_code, code_len)) return 0;

    /* --- Gate 1b: scooter_code (field[1]) is the unreserved charset ---
     * Strictly redundant HERE — a code that equals this lock's provisioned one
     * is already whatever that one is — and it is not redundant across the
     * three readers, which is the only reason it exists. The server's
     * RentalTokenIssuer.verify is not a lock and has no code to compare
     * against, so the charset is the whole of what holds field 1 THERE; a lock
     * that skipped it would be answering a narrower question than the reader
     * beside it, and ../RENTAL_TOKEN.md states one rule for both. It also
     * makes the lock's own provisioning explicit: a lock baked with a code
     * outside this set would refuse every token, including its own.
     */
    if (!is_unreserved(field_start[1], field_len[1])) return 0;

    /* --- Gate 1c: reservation_id (field[2]) is the unreserved charset ---
     * The lock does not act on this field. It is held to the charset for the
     * reason Gate 2 holds `iat`: a field nobody parses is a field every reader
     * may read differently, and this is the field where the three can diverge
     * most widely. Without this gate the lock takes a byte no UTF-8 decoder
     * accepts while both Ruby readers turn it away, which makes the PHYSICAL
     * LOCK the widest reader of the credential — the one direction that is not
     * fail-closed at the scooter.
     */
    if (!is_unreserved(field_start[2], field_len[2])) return 0;

    /* --- Gate 2: iat (field[3]) must be 1-20 ASCII digits ---
     * The lock does not ACT on iat — exp alone bounds the window — but it does
     * insist the field is the decimal integer the grammar says it is. The
     * alternative is a field nobody parses, and a field nobody parses is a
     * field every reader may read differently: this gate is what stops the
     * lock accepting an `iat` the server's own verifier refuses.
     */
    if (!parse_uint64(field_start[3], field_len[3], &iat_val)) return 0;
    (void)iat_val; /* syntax is the whole of the check */

    /* --- Gate 3: exp (field[4]) must be 1-20 ASCII digits AND > now_unix ---
     * parse_uint64 takes digits only: no sign, no separator, no surrounding
     * space, and no value past UINT64_MAX. That is narrower than a permissive
     * integer parse on purpose — see ../RENTAL_TOKEN.md for why the three
     * readers spell this the same way.
     */
    if (!parse_uint64(field_start[4], field_len[4], &exp_val)) return 0;
    if (exp_val <= now_unix) return 0;

    /* --- Gate 4: jti (field[5]) must be 32 lowercase hex characters --- */
    if (!is_jti(field_start[5], field_len[5])) return 0;

    /* --- All checks passed --- */
    return 1;
}

/* --------------------------------------------------------------------------
 * skooti_verify_token — the NUL-terminated entry point.
 *
 * Its contract is a C string, so it measures the length itself and hands the
 * same parser the same question skooti_verify_wire hands it.
 * -------------------------------------------------------------------------- */

int skooti_verify_token(const uint8_t pubkey[32],
                        const char   *token,
                        const char   *my_scooter_code,
                        uint64_t      now_unix)
{
    if (!token) return 0;

    return verify_bounded(pubkey, token, strnlen(token, SKOOTI_TOKEN_MAX + 1),
                          my_scooter_code, now_unix);
}

/* --------------------------------------------------------------------------
 * skooti_verify_wire — verify a token whose LENGTH the caller knows.
 *
 * The caller here is whoever received bytes: the sketch's BLE onWrite handler
 * with the write's own size, the crosscheck helper with the file's. Two things
 * a `const char *` alone cannot do are done here with that count.
 *
 * A NUL is refused rather than read past. skooti_verify_token ends at the
 * first one, whatever the caller was handed, so a buffer holding one would be
 * verified as the prefix before it and the bytes after it — chosen by the
 * writer, covered by no signature — would never be looked at. The grammar in
 * ../RENTAL_TOKEN.md admits no NUL in a wire token, so a buffer carrying one
 * is refused whole.
 *
 * And the count BOUNDS the parse: verify_bounded is given token_len rather
 * than a pointer to walk, so no byte at or past token_len is ever read. A
 * caller whose buffer is not terminated at token_len — a socket, a ring
 * buffer, a BLE reassembly — is answered without a read past its end, and a
 * caller that declares a length shorter than the terminated content gets the
 * SHORTER token verified rather than the longer one it did not declare. Both
 * of those require the count to reach the parser, which is why it does.
 * -------------------------------------------------------------------------- */

/* --------------------------------------------------------------------------
 * wire_bounds_ok — the precondition BOTH length-aware entry points state.
 *
 * A non-empty buffer, within the cap, holding no NUL inside the count the
 * caller declared. One statement of it rather than two, because the verify
 * path and the jti path are handed the same buffer and the same count and a
 * pair that drifted would let the replay store be keyed off a walk the verify
 * had refused to make.
 * -------------------------------------------------------------------------- */

static int wire_bounds_ok(const char *token, size_t token_len)
{
    if (token_len == 0 || token_len > SKOOTI_TOKEN_MAX) return 0;

    /* strnlen stops at the first NUL: a shorter answer means one is in there. */
    if (strnlen(token, token_len) != token_len) return 0;

    return 1;
}

int skooti_verify_wire(const uint8_t pubkey[32],
                       const char   *token,
                       size_t        token_len,
                       const char   *my_scooter_code,
                       uint64_t      now_unix)
{
    if (!token) return 0;
    if (!wire_bounds_ok(token, token_len)) return 0;

    return verify_bounded(pubkey, token, token_len, my_scooter_code, now_unix);
}

/* --------------------------------------------------------------------------
 * parse_jti_bounded — extract jti from a verified token (field [5]), over
 * EXACTLY token_len bytes, and the two entry points below it.
 *
 * message: "kiosk-rental-v1|<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>"
 * field indices: [0]=tag [1]=scooter_code [2]=reservation_id [3]=iat [4]=exp [5]=jti
 * We skip the first 5 pipe-delimited fields to reach jti at field[5], and what
 * is left must be the jti ALONE — a further '|' means the message is not six
 * fields, so this reports failure rather than handing the replay store a key
 * with someone else's bytes glued to it — and it must be 32 lowercase hex, the
 * same charset skooti_verify_token's Gate 4 demands. Those two gates are stated
 * here in the same terms that one states them in, because a caller that reached
 * here through some other path must not get a laxer answer than that one gives.
 * -------------------------------------------------------------------------- */

static int parse_jti_bounded(const char *token, size_t token_len,
                             char *jti_out, size_t jti_out_sz)
{
    size_t  dot_pos;
    size_t  msg_len;
    const char *msg;
    const char *p;
    size_t  remaining;
    int     f;

    if (!token || !jti_out || jti_out_sz == 0) return 0;

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

    /* Skip 5 pipe-delimited fields to reach jti (field[5]) */
    for (f = 0; f < 5; f++) {
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

    /* ...and it must be the last field: no further '|' */
    {
        size_t j;
        for (j = 0; j < remaining; j++) {
            if (p[j] == '|') return 0; /* more than 6 fields */
        }
    }

    /* ...and it must be the jti charset the grammar declares */
    if (!is_jti(p, remaining)) return 0;

    memcpy(jti_out, p, remaining);
    jti_out[remaining] = '\0';
    return 1;
}

int skooti_parse_jti(const char *token, char *jti_out, size_t jti_out_sz)
{
    if (!token) return 0;

    return parse_jti_bounded(token, strnlen(token, SKOOTI_TOKEN_MAX + 1),
                             jti_out, jti_out_sz);
}

/* --------------------------------------------------------------------------
 * skooti_parse_jti_n — the jti of a token whose LENGTH the caller knows.
 *
 * skooti_verify_wire exists so a length-carrying caller never has its buffer
 * read past; a caller that then reached for the jti through the terminated
 * entry point would give that property straight back, because the replay key
 * would be taken with a walk this one had refused to make. The sketch calls
 * this one with the BLE write's own size, so the whole board path — verify,
 * then key the replay store — is bounded by the count the radio reported.
 * -------------------------------------------------------------------------- */

int skooti_parse_jti_n(const char *token, size_t token_len,
                       char *jti_out, size_t jti_out_sz)
{
    if (!token) return 0;
    if (!wire_bounds_ok(token, token_len)) return 0;

    return parse_jti_bounded(token, token_len, jti_out, jti_out_sz);
}
