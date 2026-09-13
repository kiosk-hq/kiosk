# frozen_string_literal: true

# token_vectors.rb — the rental-token conformance vectors, shared by every
# reader of the token.
#
# WHY THIS FILE EXISTS. The skooti rental token has THREE readers: the C
# verifier this directory ships (`verify.c`, linked by `skooti_lock.ino`),
# `RentalTokenIssuer.verify` on the server, and `script/lock_sim.rb`. They are
# deliberately independent implementations — that independence is what makes a
# crosscheck worth running — and independence with nothing holding it is just
# divergence waiting to be found by whoever attacks the parse first. The
# languages make that cheap: `String#split("|")` drops trailing empty fields
# where the C parser counts them, `Integer(s, 10)` reads `+1750001900` where
# `parse_uint64` refuses it, and a field no reader parses is a field each
# reader may read differently.
#
# So what holds the three together is not three carefully-reviewed parsers. It
# is ONE set of vectors and a gate that runs every reader against it: `make
# crosscheck`, via crosscheck_grammar.rb. A divergence on any axis this file
# covers is a red build rather than something a reader has to go looking for.
#
# THE GRAMMAR THESE VECTORS PIN is stated once, in ../RENTAL_TOKEN.md, which is
# the canonical page for this token. In brief: the wire token is at most 512
# bytes and splits at its LAST "." into a message and an unpadded base64url
# Ed25519 signature; the message is exactly six pipe-delimited fields, none of
# them empty; field 0 is the literal domain tag, field 1 the scooter code,
# field 2 an opaque reservation id, fields 3 and 4 are 1-20 plain ASCII digits
# no greater than UINT64_MAX, and field 5 is 32 lowercase hex characters.
#
# EVERY VECTOR IS SIGNED WITH THE LIVE DEV KEY by whoever runs it — the same
# `config/dev_unlock_key.pem` the server signs with — and that is the whole
# point of holding messages here rather than wire tokens. A wrong-shaped
# message carrying a junk signature is refused by the signature gate first, so
# it proves nothing about the parse. These vectors reach the parse.
#
# WHAT THIS SET DOES NOT COVER, so nobody reads it as more than it is:
#   * Signature handling — a flipped byte, an oversized sig field, a missing
#     ".", a short sig. Those are host_test.c's cases on the C side and the
#     KAT's on the Ruby side, and they are refused before the parse runs.
#   * The scooter-code binding as a NEGATIVE. No vector holds a well-formed
#     message with a scooter code OTHER than SCOOTER_CODE, because
#     `RentalTokenIssuer.verify` is not a lock and has no provisioned code to
#     compare against — a wrong-code vector would be asking the three readers a
#     question only two of them are given the input to answer. Two vectors DO
#     carry something else in field 1 (an empty one, and the tag itself pushed
#     along by a leading delimiter), and both are refused on the grammar before
#     any code comparison is reached.
#   * The exp==now boundary. Every vector sits strictly inside or strictly
#     outside the window: measured over this table, no vector's field 4 is the
#     plain integer NOW.
#   * Replay. The jti store is per-reader state, not a property of the token.

module SkootiTokenVectors
  # The clock every reader is run at. crosscheck_main.c compiles the same value
  # into CROSSCHECK_NOW; changing one without the other makes the set lie.
  NOW = 1_750_001_800

  # The code the C helper is provisioned with. It is field 1 of every vector
  # except the two the header names, which put something else there on purpose.
  SCOOTER_CODE = "SK-001"

  # A well-formed jti: 32 lowercase hex, exactly what SecureRandom.hex(16) mints.
  JTI = "deadbeef00112233445566778899aabb"

  # Inside the window (NOW < EXP) and behind it.
  EXP      = "1750001900"
  EXP_PAST = "1750001700"
  IAT      = "1750001000"

  # axis    — the property the vector attacks; printed so a failure names it
  # label   — one line, human, no trailing punctuation
  # accept  — what EVERY reader must answer at NOW
  # message — the bytes to sign; the runner appends "." + the live signature
  Vector = Struct.new(:axis, :label, :accept, :message)

  # Build a message, overriding one field at a time. `suffix` is appended after
  # the jti, which is how the delimiter-count vectors are spelled.
  def self.msg(tag: "kiosk-rental-v1", code: SCOOTER_CODE, resv: "resv-live",
               iat: IAT, exp: EXP, jti: JTI, suffix: "")
    "#{tag}|#{code}|#{resv}|#{iat}|#{exp}|#{jti}#{suffix}"
  end

  def self.v(axis, label, accept, message)
    Vector.new(axis, label, accept, message)
  end

  # A reservation id long enough to put the wire token at exactly the lock's
  # 512-byte cap, and one byte more. DERIVED rather than typed: everything in
  # the message but the reservation id, plus the "." and the 86 unpadded
  # base64url characters a 64-byte Ed25519 signature encodes to.
  SIG_WIRE_LEN = 1 + 86
  RESV_AT_CAP  = "r" * (512 - SIG_WIRE_LEN - msg(resv: "").bytesize)
  RESV_OVER    = "#{RESV_AT_CAP}r"

  VECTORS = [
    # ── count: how many pipe-delimited fields the message carries ────────────
    # The four rows this set inherits from the field-count crosscheck, plus the
    # trailing-delimiter shapes that set could not see because all four of its
    # messages ended in a non-empty field.
    v("count",  "six fields, well-formed",                  true,  msg),
    v("count",  "five fields, jti absent",                  false,
      "kiosk-rental-v1|#{SCOOTER_CODE}|resv-live|#{IAT}|#{EXP}"),
    v("count",  "seven fields, one appended after the jti", false, msg(suffix: "|EXTRA")),
    v("count",  "eight fields, pipe-input shift, exp faked", false,
      "kiosk-rental-v1|#{SCOOTER_CODE}|r|#{IAT}|9999999999|#{IAT}|#{EXP}|#{JTI}"),
    v("count",  "seven segments, one trailing delimiter",   false, msg(suffix: "|")),
    v("count",  "eight segments, two trailing delimiters",  false, msg(suffix: "||")),
    v("count",  "seven segments, one leading delimiter",    false, "|#{msg}"),

    # ── empty: a field that is present but has no bytes ──────────────────────
    v("empty",  "empty scooter_code",                       false, msg(code: "")),
    v("empty",  "empty reservation_id",                     false, msg(resv: "")),
    v("empty",  "empty iat",                                false, msg(iat: "")),
    v("empty",  "empty exp",                                false, msg(exp: "")),
    v("empty",  "empty jti",                                false, msg(jti: "")),

    # ── tag: the domain-separation tag in field 0 ────────────────────────────
    v("tag",    "wrong tag, validly signed",                false, msg(tag: "kiosk-rental-v0")),
    v("tag",    "right tag with a trailing space",          false, msg(tag: "kiosk-rental-v1 ")),

    # ── integer: what an iat or an exp may be spelled as ─────────────────────
    v("int",    "exp with a leading plus",                  false, msg(exp: "+#{EXP}")),
    v("int",    "exp with underscore separators",           false, msg(exp: "1_750_001_900")),
    v("int",    "exp with a leading space",                 false, msg(exp: " #{EXP}")),
    v("int",    "exp with a trailing space",                false, msg(exp: "#{EXP} ")),
    v("int",    "exp in hexadecimal",                       false, msg(exp: "0x684d84ec")),
    v("int",    "exp negative",                             false, msg(exp: "-1")),
    v("int",    "exp of 21 digits",                         false, msg(exp: "9" * 21)),
    v("int",    "exp of 20 digits, past UINT64_MAX",        false, msg(exp: "9" * 20)),
    v("int",    "exp with leading zeros, in window",        true,  msg(exp: "00000000#{EXP}")),
    v("int",    "iat not a number",                         false, msg(iat: "abc")),
    v("int",    "iat with a leading plus",                  false, msg(iat: "+#{IAT}")),
    v("int",    "iat of 21 digits",                         false, msg(iat: "9" * 21)),
    v("int",    "iat negative",                             false, msg(iat: "-5")),

    # ── jti: the replay key, and the only field with a fixed width ───────────
    v("jti",    "jti of 31 hex characters",                 false, msg(jti: JTI[0..-2])),
    v("jti",    "jti of 33 hex characters",                 false, msg(jti: "#{JTI}c")),
    v("jti",    "jti in uppercase hex",                     false, msg(jti: JTI.upcase)),
    v("jti",    "jti of 32 non-hex characters",             false, msg(jti: "z" * 32)),
    v("jti",    "jti of 64 hex characters",                 false, msg(jti: JTI * 2)),

    # ── length: the wire cap the lock enforces before it touches the parse ───
    v("length", "wire token at exactly 512 bytes",          true,  msg(resv: RESV_AT_CAP)),
    v("length", "wire token one byte over 512",             false, msg(resv: RESV_OVER)),

    # ── freshness: exp against the injected clock, away from the boundary ────
    v("fresh",  "exp strictly in the past",                 false, msg(exp: EXP_PAST)),
  ].freeze

  # The axes covered, in the order they first appear. Derived from the vectors
  # so it can never disagree with them.
  def self.axes
    VECTORS.map(&:axis).uniq
  end
end
