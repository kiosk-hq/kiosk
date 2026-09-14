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
