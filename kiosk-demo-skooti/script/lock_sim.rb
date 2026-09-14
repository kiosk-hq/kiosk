# frozen_string_literal: true

require "openssl"
require "base64"

# Software simulator of the ESP32 BLE scooter lock firmware (offline Ed25519).
#
# The physical lock:
#   1. Baked at provisioning with:
#      - the skooti Ed25519 PUBLIC key (32 bytes)
#      - its own SCOOTER_CODE
#   2. On a BLE unlock request it receives the wire rental token:
#        "kiosk-rental-v1|<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>.<base64url(sig)>"
#      a. Splits on the LAST "."
#      b. Base64url-decodes the sig — unpadded, canonical, exactly 64 bytes
#      c. Ed25519-verifies the sig over the message bytes
#      d. Parses the 6 pipe-separated fields, every one of them non-empty
#      e. Checks: field 0 == "kiosk-rental-v1" (domain-separation tag)
#      f. Checks: iat and exp are 1-20 plain digits, jti is 32 lowercase hex
#      g. Checks: scooter_code == own code, exp > now (injected clock)
#      h. Checks jti NOT in the consumed store (durable replay prevention)
#      i. On all checks passing: records jti → exp in the consumed store, unlocks
#
# The grammar step (d/f) is the firmware's, byte for byte: the lock's C parser
# walks pipes and refuses an empty field, a non-digit timestamp or a jti that is
# not 32 lowercase hex, and this simulator would be worthless if it were more
# permissive than the thing it simulates. RENTAL_TOKEN.md states that grammar
# once; `cd firmware && make crosscheck` runs one shared vector set through this
# reader, RentalTokenIssuer.verify and the C verifier, and fails on any
# disagreement.
#
# Durable jti store: @consumed_jtis is a { jti => exp } map.
#   - Replay check: reject if jti present AND stored_exp >= now (still in window).
#   - On accept: record jti => exp.
#   - Opportunistic pruning: remove entries whose exp < now on each unlock call.
# This models the firmware's NVS jti store: bounded set, exp-scoped, reboot-durable.
#
# This simulator reproduces that exact logic so the agent-side driver can be
# tested without real hardware.
#
# NO HMAC, no nonce/challenge — this is a pure offline verify path.

LOCK_SIM_CONTEXT_TAG = "kiosk-rental-v1"

# The grammar the firmware enforces, mirrored here. Each limit is the lock's
# own: SKOOTI_TOKEN_MAX, the sig-length guard, parse_uint64 and is_jti in
# firmware/verify.c. RENTAL_TOKEN.md states them in prose.
LOCK_SIM_TOKEN_MAX_BYTES  = 512
LOCK_SIM_SIG_B64_MAX      = 88
# base64url, RFC 4648 §5, UNPADDED — a charset gate in front of the decode.
# Base64.urlsafe_decode64 translates "-_" to "+/" and pads a short input before
# decoding, so without this it would accept a signature spelled in the STANDARD
# alphabet or with "=" padding; the lock's character table gives -1 for "+",
# "/" and "=" alike.
LOCK_SIM_SIG_B64_FORMAT   = /\A[A-Za-z0-9\-_]+\z/
# The lock reads the BLE write as a NUL-terminated C string, so a NUL byte does
# not appear IN a token — it ENDS one, and everything after it is invisible to
# the verifier that decides whether the scooter opens. A Ruby String carries the
# byte and would read past it, which is this simulator answering a question the
# firmware was never asked.
LOCK_SIM_NUL_BYTE         = "\u0000".b
LOCK_SIM_FIELD_COUNT      = 6
LOCK_SIM_DELIMITER        = "|"
LOCK_SIM_TIMESTAMP_FORMAT = /\A[0-9]{1,20}\z/
LOCK_SIM_TIMESTAMP_MAX    = (1 << 64) - 1
LOCK_SIM_JTI_FORMAT       = /\A[0-9a-f]{32}\z/

class LockSim
  # @param scooter_code     [String]              the code this lock is provisioned with
  # @param skooti_public_key [OpenSSL::PKey::PKey | String]
  #   Either an OpenSSL Ed25519 public-key object OR its raw 32 bytes (binary String).
  def initialize(scooter_code:, skooti_public_key:)
    @scooter_code = scooter_code.to_s

    @pub_key = case skooti_public_key
               when OpenSSL::PKey::PKey
                 skooti_public_key
               when String
                 # Accept raw 32-byte binary OR hex string — normalise to OpenSSL key.
                 raw = skooti_public_key.length == 32 ? skooti_public_key : [skooti_public_key].pack("H*")
                 # Ed25519 SubjectPublicKeyInfo DER = 12-byte header + 32-byte key.
                 header = "\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00"
                 der    = header + raw
                 OpenSSL::PKey.read(der)
               else
                 raise ArgumentError, "skooti_public_key must be an OpenSSL::PKey::PKey or a 32-byte String"
               end

    # Durable jti store: { jti (String) => exp (Integer unix seconds) }.
    # Entries are retained until their exp passes; the lock rejects any token
    # whose jti is present AND whose stored exp >= now (still within the window).
    @consumed_jtis = {}
  end

  # Verify and consume a rental token (domain-separation tag + durable replay prevention).
  #
  # Returns +false+ if:
  #   - token is malformed, over 512 bytes, or holds a NUL byte
  #   - the signature field is not unpadded base64url, or does not decode to 64 bytes
  #   - Ed25519 signature is invalid
  #   - the message is not exactly 6 pipe-delimited non-empty fields
  #   - field 0 != "kiosk-rental-v1" (wrong or missing domain-separation tag)
  #   - iat or exp is not 1-20 plain digits, or jti is not 32 lowercase hex
  #   - scooter_code in the token does not match this lock's code
  #   - exp <= now  (expired)
  #   - jti was already consumed within its exp window (durable replay prevention)
  # Returns +true+ and records jti => exp on success (one-shot within exp window).
  #
  # @param token [String]  wire token: "<message>.<base64url(sig)>"
  # @param now   [Integer] current unix timestamp (seconds), injected for testing
  # @return [Boolean]
  def unlock(token:, now:)
    return false if token.nil? || token.empty?

    # Gate: wire length — the lock's own SKOOTI_TOKEN_MAX.
    return false if token.bytesize > LOCK_SIM_TOKEN_MAX_BYTES

    # Gate: no NUL byte — the firmware would see the prefix and nothing more.
    return false if token.b.include?(LOCK_SIM_NUL_BYTE)

    # Split on the LAST "." — the message itself contains "|" but no ".".
    dot_idx = token.rindex(".")
    return false if dot_idx.nil?

    message = token[0...dot_idx]
    sig_b64 = token[(dot_idx + 1)..]

    return false if message.empty? || sig_b64.empty?
    return false if sig_b64.bytesize > LOCK_SIM_SIG_B64_MAX
    return false unless sig_b64.match?(LOCK_SIM_SIG_B64_FORMAT)

    # Decode sig — base64url, no padding.
    sig = Base64.urlsafe_decode64(sig_b64)
    return false if sig.bytesize != 64

    # Ed25519-verify: OpenSSL's verify(nil, sig, msg) — nil digest = pure EdDSA.
    return false unless @pub_key.verify(nil, sig, message)

    # Parse the 6 pipe-delimited fields (field 0 is the domain-separation tag).
    # The NEGATIVE limit is load-bearing: plain String#split("|") drops trailing
    # empty fields, so a signed message with a delimiter appended would read
    # back as six here and be accepted, where the lock's C parser — which walks
    # pipes and finds one in the last field — refuses it.
    fields = message.split(LOCK_SIM_DELIMITER, -1)
    return false unless fields.length == LOCK_SIM_FIELD_COUNT
    return false if fields.any?(&:empty?)

    context_tag, token_scooter, _reservation_id, iat_s, exp_s, jti = fields

    # Gate: domain-separation — field 0 must be the known context tag.
    return false unless context_tag == LOCK_SIM_CONTEXT_TAG

    # Gate: scooter code must match what this lock is provisioned with.
    return false unless token_scooter == @scooter_code

    # Gate: field charsets. iat is not acted on — exp alone bounds the window —
    # but it is held to the grammar all the same, because a field nobody parses
    # is a field each reader may read differently.
    return false unless lock_sim_timestamp?(iat_s)
    return false unless lock_sim_timestamp?(exp_s)
    return false unless jti.match?(LOCK_SIM_JTI_FORMAT)

    # Gate: freshness — exp must be strictly greater than now.
    exp = Integer(exp_s, 10)
    return false unless exp > now

    # Opportunistic pruning: remove jti entries whose window has already closed.
    @consumed_jtis.delete_if { |_j, stored_exp| stored_exp < now }

    # Gate: durable replay prevention — reject if the jti is present AND its
    # stored exp >= now (still within the original token's validity window).
    if @consumed_jtis.key?(jti) && @consumed_jtis[jti] >= now
      return false
    end

    # All checks passed — record jti => exp and unlock.
    @consumed_jtis[jti] = exp
    true
  rescue ArgumentError, OpenSSL::PKey::PKeyError
    false
  end

  private

  # True when +s+ is the decimal integer the grammar admits for iat and exp:
  # 1-20 plain ASCII digits and no value past UINT64_MAX — what the firmware's
  # parse_uint64 accepts, and narrower than Integer(s, 10), which also takes a
  # sign, underscore separators and surrounding whitespace.
  #
  # @param s [String]
  # @return [Boolean]
  def lock_sim_timestamp?(s)
    return false unless s.match?(LOCK_SIM_TIMESTAMP_FORMAT)

    Integer(s, 10) <= LOCK_SIM_TIMESTAMP_MAX
  end
end
