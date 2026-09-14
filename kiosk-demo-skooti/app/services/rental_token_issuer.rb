# frozen_string_literal: true

require "openssl"
require "base64"
require "securerandom"

# Ed25519 offline rental-token authority for the skooti demo — a scooter-rental
# concern, deliberately not part of the domain-neutral kiosk-server core.
#
# The scooter verifies the signed rental token itself, with no server round-trip
# at unlock time: skooti signs with its Ed25519 private key (sourced from
# DevUnlockKey into Kiosk.configuration.unlock_signing_key in
# config/initializers/kiosk.rb) and the public key is baked into every lock at
# provisioning time.
#
# Canonical token wire format (split on the LAST "."):
#   "<context_tag>|<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>.<base64url(sig)>"
#
# Signed message (UTF-8, exact bytes):
#   "kiosk-rental-v1|<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>"
#   Field 0 is the fixed domain-separation context tag, and the lock accepts a
#   token ONLY if it equals CONTEXT_TAG — that is what stops the signing key
#   being cross-used to mint anything else a lock would accept.
#   iat/exp are unix seconds as decimal strings; jti = SecureRandom.hex(16).
#
# The GRAMMAR — how many fields, what each field may contain, and how the
# delimiter behaves — is written out in RENTAL_TOKEN.md, the canonical page for
# this token. {.verify} below implements exactly that grammar, and so do the
# two other readers this token has: script/lock_sim.rb and the firmware's
# skooti_verify_token. `cd firmware && make crosscheck` runs one shared vector
# set through all three and fails on any disagreement.
#
# Signature: Ed25519 over the message bytes (64 bytes, deterministic).
# Crypto: OpenSSL::PKey Ed25519 — key.sign(nil, message) / key.verify(nil, sig, msg).
#
# This exact format is reproduced (byte-identical) in:
#   - script/lock_sim.rb         (the software lock simulator)
#   - firmware/host_test.c       (the C cross-check host test)
#   - firmware/skooti_lock.ino   (the ESP32 lock firmware)
# DO NOT CHANGE without updating all sites and re-recording the known-answer vector.
module RentalTokenIssuer
  # Field 0 of every signed message; the lock accepts nothing else.
  CONTEXT_TAG = "kiosk-rental-v1"

  # ── The grammar {.verify} enforces, spelled the way the C lock spells it ──
  #
  # Each constant below is a limit the lock enforces, restated here so this
  # verifier answers as the lock does on every byte sequence an adopter can put
  # on the wire. RENTAL_TOKEN.md states the same grammar in prose.

  # Longest wire token accepted, in bytes — SKOOTI_TOKEN_MAX in firmware/verify.h.
  TOKEN_MAX_BYTES = 512

  # Longest base64url signature field accepted — 64 bytes encode to 86
  # characters unpadded, and the lock allows a little slack over that.
  SIG_B64_MAX = 88

  # The signature alphabet: base64url, RFC 4648 §5, UNPADDED. This is a
  # charset gate in front of the decode, and it is load-bearing because
  # Base64.urlsafe_decode64 is wider than the lock's decoder in two ways it
  # does not announce — it translates "-_" to "+/" before decoding, so a
  # signature spelled in the STANDARD alphabet decodes, and it pads a short
  # input, so a signature spelled with "=" decodes. The lock's character table
  # gives -1 for "+", "/" and "=" alike. One signature, one spelling.
  SIG_B64_FORMAT = /\A[A-Za-z0-9\-_]+\z/

  # The wire token holds no NUL byte. The lock reads the BLE write as a
  # NUL-terminated C string, so a NUL does not appear IN a token — it ENDS one,
  # and every byte after it is invisible to the verifier that decides whether a
  # scooter opens. A Ruby String carries the byte happily and would read past
  # it, which is a reader answering a question the lock was never asked.
  NUL_BYTE = "\u0000".b

  # Number of fields in the signed message, and the delimiter between them.
  FIELD_COUNT = 6
  DELIMITER   = "|"

  # iat and exp: 1-20 plain ASCII digits and no more than UINT64_MAX, which is
  # what the lock's parse_uint64 accepts. Deliberately narrower than
  # Integer(s, 10), which also takes a sign, underscore separators and
  # surrounding whitespace — none of which the lock would honour.
  TIMESTAMP_FORMAT = /\A[0-9]{1,20}\z/
  TIMESTAMP_MAX    = (1 << 64) - 1

  # jti: exactly what SecureRandom.hex(16) produces.
  JTI_FORMAT = /\A[0-9a-f]{32}\z/

  class << self
    # Issue a signed rental token.
    #
    # Charset contract: `scooter_code` and `reservation_id` MUST be non-empty
    # and MUST NOT contain the field delimiter `|`. The message packs six
    # pipe-delimited fields and {.verify} rejects any split that does not yield
    # exactly 6 non-empty ones, so a `|` in either input mints a validly SIGNED
    # token this issuer's own verifier rejects — a field-shift hazard for a
    # laxer external verifier. The two other verifiers skooti ships are not
    # lax: `script/lock_sim.rb` and the lock firmware's `skooti_verify_token`
    # hold the same grammar, and `make crosscheck` runs one shared vector set
    # through all three. skooti only ever passes `SK-###` codes and pipe-free
    # ids, so this is a documented input precondition rather than an enforced
    # guard.
    #
    # @param scooter_code   [String]  e.g. "SK-001" (no `|`)
    # @param reservation_id [String]  UUID or other opaque ID (no `|`)
    # @param now            [Integer] current unix timestamp (seconds)
    # @param ttl            [Integer] token lifetime in seconds (default 900 = 15 min)
    # @return [String] wire token: "<message>.<base64url_sig>"
    def issue(scooter_code:, reservation_id:, now:, ttl: 900)
      key = signing_key
      raise ArgumentError, "unlock_signing_key is not configured" if key.nil?

      iat     = now
      exp     = iat + ttl
      jti     = SecureRandom.hex(16)
      message = "#{CONTEXT_TAG}|#{scooter_code}|#{reservation_id}|#{iat}|#{exp}|#{jti}"
      sig     = key.sign(nil, message)
      "#{message}.#{Base64.urlsafe_encode64(sig, padding: false)}"
    end

    # Verify a wire token against the configured signing key: refuse a NUL
    # byte, split on the LAST ".", hold the signature to the unpadded base64url
    # alphabet and decode it, Ed25519-verify the message, hold the message to
    # the grammar above, and require exp > now.
    #
    # Reference-verifier surface — the production unlock path never calls this;
    # the scooter lock (script/lock_sim.rb / the firmware) does the verifying.
    # This Ruby verifier is the known-answer-vector anchor the KAT
    # (script/rental_token_issuer_kat.rb) runs the firmware's expected wire vector
    # through, so the byte-exact contract stays cross-checked without a lock.
    #
    # @param token [String] wire token
    # @param now   [Integer] current unix timestamp (seconds)
    # @return [Hash|nil] parsed claims hash, or nil on any failure
    def verify(token:, now:)
      return nil if token.nil? || token.empty?
      return nil if token.bytesize > TOKEN_MAX_BYTES
      return nil if token.b.include?(NUL_BYTE)

      dot_idx = token.rindex(".")
      return nil if dot_idx.nil?

      message = token[0...dot_idx]
      sig_b64 = token[(dot_idx + 1)..]

      return nil if message.empty? || sig_b64.empty?
      return nil if sig_b64.bytesize > SIG_B64_MAX
      return nil unless sig_b64.match?(SIG_B64_FORMAT)

      sig = Base64.urlsafe_decode64(sig_b64)
      return nil unless sig.bytesize == 64

      pub = public_key
      return nil if pub.nil?

      return nil unless pub.verify(nil, sig, message)

      # Split with a NEGATIVE limit. Plain String#split("|") DROPS trailing
      # empty fields, so a message with a delimiter appended to it — seven
      # fields, the last one empty — would read back as six and be accepted
      # here while the lock refused it. The limit is what makes this count the
      # delimiters the way the C parser walks them.
      fields = message.split(DELIMITER, -1)
      return nil unless fields.length == FIELD_COUNT
      return nil if fields.any?(&:empty?)
      return nil unless fields[0] == CONTEXT_TAG

      _tag, scooter_code, reservation_id, iat_s, exp_s, jti = fields

      return nil unless timestamp?(iat_s)
      return nil unless timestamp?(exp_s)
      return nil unless jti.match?(JTI_FORMAT)

      iat = Integer(iat_s, 10)
      exp = Integer(exp_s, 10)

      # Freshness: the window is `now < exp`, so a token whose exp is exactly
      # now is spent. The lock is the enforcement point and refuses that
      # instant; this verifier answers as the lock does.
      return nil unless exp > now

      {
        scooter_code:   scooter_code,
        reservation_id: reservation_id,
        iat:            iat,
        exp:            exp,
        jti:            jti,
      }
    rescue ArgumentError, OpenSSL::PKey::PKeyError
      nil
    end

    # The public key PEM derived from the CONFIGURED signing key.
    #
    # KAT-anchor surface: provisioning reads the public key from the fixed dev
    # keypair via {DevUnlockKey.public_key_pem}, which needs no configured key.
    # This helper derives the same value from the configuration instead, so the
    # KAT can cross-check two deliberately independent derivations.
    #
    # @return [String] PEM
    def public_key_pem
      public_key.public_to_pem
    end

    # The raw 32-byte Ed25519 public key as lowercase hex — the value baked into
    # each scooter lock's firmware. An Ed25519 DER public key is a 12-byte header
    # plus the 32-byte raw key, hence the tail slice.
    #
    # KAT-anchor surface (see {.public_key_pem}): the firmware fixture comes from
    # {DevUnlockKey.public_key_raw32_hex} and the KAT asserts this equals it.
    #
    # @return [String] 64 lowercase hex chars
    def public_key_raw32_hex
      der = public_key.public_to_der
      der[-32..].unpack1("H*")
    end

    private

    # True when +s+ is the decimal integer the grammar admits for iat and exp:
    # 1-20 plain ASCII digits, no sign, no separator, no surrounding space, and
    # no value past UINT64_MAX. The regexp alone is not enough — twenty digits
    # can still exceed UINT64_MAX, and the lock's parse_uint64 refuses that.
    #
    # @param s [String]
    # @return [Boolean]
    def timestamp?(s)
      return false unless s.match?(TIMESTAMP_FORMAT)

      Integer(s, 10) <= TIMESTAMP_MAX
    end

    def signing_key
      Kiosk.configuration.unlock_signing_key
    end

    def public_key
      key = signing_key
      return nil if key.nil?

      OpenSSL::PKey.read(key.public_to_pem)
    end
  end
end
