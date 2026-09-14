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
# languages make that cheap, and every one of these is a property of the
# language rather than a slip anyone can review away:
#
#   * `String#split("|")` DROPS trailing empty fields where the C parser counts
#     them.
#   * `Integer(s, 10)` reads `+1750001900` where `parse_uint64` refuses it.
#   * `Base64.urlsafe_decode64` translates `-_` to `+/` and pads a short input
#     before decoding, so it reads two spellings the lock's character table
#     gives -1 for.
#   * A base64 decoder that drops the leftover bits of the final character
#     admits sixteen spellings of one 64-byte signature; a strict one admits
#     the single canonical spelling.
#   * A Ruby String carries a NUL byte and reads past it; a `const char *`
#     ends there.
#   * A field no reader parses is a field each reader may read differently.
#
# So what holds the three together is not three carefully-reviewed parsers. It
# is ONE set of vectors and a gate that runs every reader against it: `make
# crosscheck`, via crosscheck_grammar.rb. A divergence on any axis this file
# covers is a red build rather than something a reader has to go looking for.
#
# THE GRAMMAR THESE VECTORS PIN is stated once, in ../RENTAL_TOKEN.md, which is
# the canonical page for this token. In brief: the wire token is at most 512
# bytes, holds no NUL, and splits at its LAST "." into a message and a
# canonical unpadded base64url Ed25519 signature; the message is exactly six
# pipe-delimited fields, none of them empty; field 0 is the literal domain tag,
# field 1 the scooter code, field 2 an opaque reservation id, fields 3 and 4
# are 1-20 plain ASCII digits no greater than UINT64_MAX with `exp > now`, and
# field 5 is 32 lowercase hex characters.
#
# THE PAGE AND THIS FILE ANSWER TO EACH OTHER, and that is checked rather than
# intended: each rule on that page carries a `<!-- vectors: axis -->` marker
# and `check_grammar_coverage.rb` fails when a rule names no axis, when a rule
# names an axis this file does not have, or when an axis here is named by no
# rule. Read that script's header for the two things it cannot do.
#
# EVERY VECTOR'S SIGNATURE IS COMPUTED AT RUN TIME WITH THE LIVE DEV KEY —
# the same `config/dev_unlock_key.pem` the server signs with — over that
# vector's own message, and that is the whole point of holding messages here
# rather than wire tokens. A wrong-shaped message carrying a junk signature is
# refused by the signature gate first, so it proves nothing about the parse.
# Most vectors then present that signature canonically, so the signature gate
# passes and the parse is the only thing left to answer. The vectors whose
# `wire` is not `:canonical` respell or dismantle the token around the same
# live signature: those are the encoding axes, and they are MEANT to be
# answered before the field parse is reached.
#
# WHAT THIS SET DOES NOT COVER, so nobody reads it as more than it is:
#   * Signature FORGERY, as opposed to signature ENCODING — a flipped byte, a
#     signature over other bytes, the wrong key. Those are host_test.c's cases
#     on the C side and the KAT's on the Ruby side. Every vector here carries a
#     genuine signature over its own message.
#   * The scooter-code binding as a NEGATIVE. No vector holds a well-formed
#     message with a scooter code OTHER than SCOOTER_CODE, because
#     `RentalTokenIssuer.verify` is not a lock and has no provisioned code to
#     compare against — a wrong-code vector would be asking the three readers a
#     question only two of them are given the input to answer. Three vectors DO
#     carry something else in field 1 (an empty one, one holding a NUL, and the
#     tag itself pushed along by a leading delimiter), and all three are refused
#     on the grammar before any code comparison is reached.
#   * Replay. The jti store is per-reader state, not a property of the token.
#   * Timing. The C reader compares the tag and the scooter code in constant
#     time (`ct_memeq`); the two Ruby readers use `==`. That is ONE of the
#     three, measured rather than assumed, and no vector here can see the
#     difference either way — a declared accept/reject answer is all a vector
#     carries.
#   * Any property of the token that ../RENTAL_TOKEN.md does not state. The
#     coverage gate binds this file to that page in both directions; neither
#     of them can reach an axis nobody has written down.

module SkootiTokenVectors
  # The clock every reader is run at. crosscheck_main.c compiles the same value
  # into CROSSCHECK_NOW; changing one without the other makes the set lie.
  NOW = 1_750_001_800

  # The code the C helper is provisioned with. It is field 1 of every vector
  # except the three the header names, which put something else there on purpose.
  SCOOTER_CODE = "SK-001"

  # A well-formed jti: 32 lowercase hex, exactly what SecureRandom.hex(16) mints.
  JTI = "deadbeef00112233445566778899aabb"

  # Inside the window (NOW < EXP) and behind it.
  EXP      = "1750001900"
  EXP_PAST = "1750001700"
  IAT      = "1750001000"

  # The largest value parse_uint64 and TIMESTAMP_MAX both admit, and it is far
  # in the future, so it is an ACCEPT: 20 digits is the boundary of the field's
  # width, not of the window.
  UINT64_MAX_S = "18446744073709551615"

  # One NUL byte, spelled as an escape so it is visible in a diff.
  NUL = "\u0000"

  # The base64url alphabet, in value order — RFC 4648 §5. Used to respell the
  # final character of a signature.
  B64URL = [*"A".."Z", *"a".."z", *"0".."9", "-", "_"].freeze

  # HOW A VECTOR'S WIRE TOKEN IS SPELLED around the signature the runner
  # computes over its message. `:canonical` is the shipped spelling; every other
  # entry deliberately respells or dismantles the token, and the runner FAILS
  # when one of them returns the canonical token unchanged — a transform that is
  # the identity measures nothing, and a rotated dev key can silently make one
  # so (`:standard_sig` needs a signature that actually contains a `-` or a `_`).
  WIRE = {
    canonical:        ->(m, s) { "#{m}.#{s}" },

    # 64 bytes encode to 86 unpadded characters; padding takes it to 88, which
    # is exactly the readers' cap, so the cap is not what answers this.
    padded_sig:       ->(m, s) { "#{m}.#{s}#{'=' * ((4 - (s.length % 4)) % 4)}" },

    # The STANDARD base64 alphabet: the same 64 bytes, spelled with `+` and `/`.
    standard_sig:     ->(m, s) { "#{m}.#{s.tr('-_', '+/')}" },

    # The final character of an 86-character encoding carries four bits that are
    # not part of the 64 decoded bytes. Setting them gives a different string
    # that decodes to the same signature — sixteen spellings, one of which is
    # canonical.
    noncanonical_sig: ->(m, s) { "#{m}.#{s[0..-2]}#{B64URL[B64URL.index(s[-1]) | 0x0f]}" },

    short_sig:        ->(m, s) { "#{m}.#{s[0..-2]}" },
    long_sig:         ->(m, s) { "#{m}.#{s}A" },

    # The wire shapes that never reach the field parse.
    no_dot:           ->(m, s) { "#{m}#{s}" },
    empty_sig:        ->(m, _s) { "#{m}." },
    empty_message:    ->(_m, s) { ".#{s}" },
    trailing_nul:     ->(m, s) { "#{m}.#{s}#{NUL}" },
  }.freeze

  # axis    — the property the vector attacks; printed so a failure names it
  # label   — one line, human, no trailing punctuation
  # accept  — what EVERY reader must answer at NOW
  # message — the bytes to sign
  # wire    — the key in WIRE that builds the wire token from message + signature
  Vector = Struct.new(:axis, :label, :accept, :message, :wire)

  # Build a message, overriding one field at a time. `suffix` is appended after
  # the jti, which is how the delimiter-count vectors are spelled.
  def self.msg(tag: "kiosk-rental-v1", code: SCOOTER_CODE, resv: "resv-live",
               iat: IAT, exp: EXP, jti: JTI, suffix: "")
    "#{tag}|#{code}|#{resv}|#{iat}|#{exp}|#{jti}#{suffix}"
  end

  def self.v(axis, label, accept, message, wire = :canonical)
    Vector.new(axis, label, accept, message, wire)
  end

  # A reservation id long enough to put the wire token at exactly the lock's
  # 512-byte cap, and one byte more. DERIVED rather than typed: everything in
  # the message but the reservation id, plus the "." and the 86 unpadded
  # base64url characters a 64-byte Ed25519 signature encodes to.
  SIG_WIRE_LEN = 1 + 86
  RESV_AT_CAP  = "r" * (512 - SIG_WIRE_LEN - msg(resv: "").bytesize)
  RESV_OVER    = "#{RESV_AT_CAP}r"

  # A reservation id whose live-key signature contains BOTH a `-` and a `_`, so
  # the `:standard_sig` respelling moves both halves of the alphabet difference
  # in one vector. Chosen by search over the dev key, and held by the runner's
  # identity check rather than by this comment: if the key is ever rotated and
  # this signature stops carrying either character, the run fails by name.
  RESV_ALPHABET = "resv-alt0"

  VECTORS = [
    # ── count: how many pipe-delimited fields the message carries ────────────
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
    v("tag",    "right tag with a leading space",           false, msg(tag: " kiosk-rental-v1")),
    v("tag",    "right tag in uppercase",                   false, msg(tag: "KIOSK-RENTAL-V1")),

    # ── integer: what an iat or an exp may be spelled as ─────────────────────
    v("int",    "exp with a leading plus",                  false, msg(exp: "+#{EXP}")),
    v("int",    "exp with underscore separators",           false, msg(exp: "1_750_001_900")),
    v("int",    "exp with a leading space",                 false, msg(exp: " #{EXP}")),
    v("int",    "exp with a trailing space",                false, msg(exp: "#{EXP} ")),
    v("int",    "exp in hexadecimal",                       false, msg(exp: "0x684d84ec")),
    v("int",    "exp negative",                             false, msg(exp: "-1")),
    v("int",    "exp of 21 digits",                         false, msg(exp: "9" * 21)),
    v("int",    "exp of 21 digits, leading zeros, in window", false, msg(exp: "#{'0' * 11}#{EXP}")),
    v("int",    "exp of 20 digits, past UINT64_MAX",        false, msg(exp: "9" * 20)),
    v("int",    "exp of exactly UINT64_MAX",                true,  msg(exp: UINT64_MAX_S)),
    v("int",    "exp with leading zeros, in window",        true,  msg(exp: "00000000#{EXP}")),
    v("int",    "iat not a number",                         false, msg(iat: "abc")),
    v("int",    "iat with a leading plus",                  false, msg(iat: "+#{IAT}")),
    v("int",    "iat of 21 digits",                         false, msg(iat: "9" * 21)),
    v("int",    "iat negative",                             false, msg(iat: "-5")),
    v("int",    "iat in non-ASCII digits",                  false, msg(iat: "١٧٥٠٠٠١٠٠٠")),
    v("int",    "iat of one digit",                         true,  msg(iat: "7")),
    v("int",    "iat equal to exp",                         true,  msg(iat: EXP)),
    v("int",    "iat far past exp",                         true,  msg(iat: "9999999999")),

    # ── jti: the replay key, and the only field with a fixed width ───────────
    v("jti",    "jti of 31 hex characters",                 false, msg(jti: JTI[0..-2])),
    v("jti",    "jti of 33 hex characters",                 false, msg(jti: "#{JTI}c")),
    v("jti",    "jti in uppercase hex",                     false, msg(jti: JTI.upcase)),
    v("jti",    "jti of 32 non-hex characters",             false, msg(jti: "z" * 32)),
    v("jti",    "jti of 64 hex characters",                 false, msg(jti: JTI * 2)),

    # ── length: the wire cap the lock enforces before it touches the parse ───
    v("length", "wire token at exactly 512 bytes",          true,  msg(resv: RESV_AT_CAP)),
    v("length", "wire token one byte over 512",             false, msg(resv: RESV_OVER)),

    # ── freshness: exp against the injected clock, boundary included ─────────
    v("fresh",  "exp one second past now",                  true,  msg(exp: (NOW + 1).to_s)),
    v("fresh",  "exp exactly now",                          false, msg(exp: NOW.to_s)),
    v("fresh",  "exp one second before now",                false, msg(exp: (NOW - 1).to_s)),
    v("fresh",  "exp strictly in the past",                 false, msg(exp: EXP_PAST)),
    v("fresh",  "iat exactly now",                          true,  msg(iat: NOW.to_s)),

    # ── sig: how the 64 signature bytes are spelled on the wire ──────────────
    v("sig",    "signature padded to 88 with equals signs", false, msg, :padded_sig),
    v("sig",    "signature in the standard base64 alphabet", false,
      msg(resv: RESV_ALPHABET), :standard_sig),
    v("sig",    "signature with a non-canonical last character", false, msg, :noncanonical_sig),
    v("sig",    "signature one character short",            false, msg, :short_sig),
    v("sig",    "signature one character long",             false, msg, :long_sig),

    # ── wire: the shape of the token around the signature ────────────────────
    v("wire",   "no dot between message and signature",     false, msg, :no_dot),
    v("wire",   "empty signature half",                     false, msg, :empty_sig),
    v("wire",   "empty message half",                       false, msg, :empty_message),

    # ── bytes: what an opaque field may hold, byte for byte ──────────────────
    v("bytes",  "NUL inside reservation_id",                false, msg(resv: "resv#{NUL}live")),
    v("bytes",  "NUL inside scooter_code",                  false, msg(code: "#{SCOOTER_CODE}#{NUL}X")),
    v("bytes",  "NUL appended to the wire token",           false, msg, :trailing_nul),
    v("bytes",  "newline inside reservation_id",            true,  msg(resv: "resv\nlive")),
    v("bytes",  "tab inside reservation_id",                true,  msg(resv: "resv\tlive")),
    v("bytes",  "0x01 inside reservation_id",               true,  msg(resv: "resv\u0001live")),
    v("bytes",  "DEL inside reservation_id",                true,  msg(resv: "resv\u007Flive")),
    v("bytes",  "multibyte UTF-8 inside reservation_id",    true,  msg(resv: "resv-Ω-live")),
  ].freeze

  # The axes covered, in the order they first appear. Derived from the vectors
  # so it can never disagree with them.
  def self.axes
    VECTORS.map(&:axis).uniq
  end
end
