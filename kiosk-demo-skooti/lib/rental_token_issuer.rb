# frozen_string_literal: true

require "openssl"
require "base64"
require "securerandom"

# Ed25519 offline rental-token authority for the skooti demo.
#
# This is a skooti-demo-local library (a scooter-rental concern), not part of
# the domain-neutral kiosk-server core. skooti is its sole consumer.
#
# The scooter verifies the signed rental token itself — no server round-trip
# at unlock time.  skooti signs with its Ed25519 private key (the demo sources
# it from DevUnlockKey and wires it into Kiosk.configuration.unlock_signing_key
# in config/initializers/kiosk.rb); the public key is baked into every lock at
# provisioning time.
#
# Canonical token wire format (split on the LAST "."):
#   "<context_tag>|<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>.<base64url(sig)>"
#
# Signed message (UTF-8, exact bytes):
#   "kiosk-rental-v1|<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>"
#   Field 0 is the fixed domain-separation context tag "kiosk-rental-v1".
#   The lock accepts a token ONLY if field 0 == CONTEXT_TAG — this prevents
#   the signing key from being cross-used to mint anything else a lock would
#   accept, and self-documents the token as a rental capability.
#   Fields 1-5: scooter_code, reservation_id, iat, exp, jti.
#   iat/exp are unix seconds as decimal strings.
#   jti = SecureRandom.hex(16)  (32 lowercase hex chars).
#
# Signature: Ed25519 over the message bytes (64 bytes, deterministic).
# Crypto: OpenSSL::PKey Ed25519 — key.sign(nil, message) / key.verify(nil, sig, msg).
#
# This exact format is reproduced (byte-identical) in:
#   - lib/lock_sim.rb            (the software lock simulator)
#   - firmware/host_test.c       (the C cross-check host test)
#   - firmware/skooti_lock.ino   (the ESP32 lock firmware)
# DO NOT CHANGE without updating all sites and re-recording the known-answer vector.
module RentalTokenIssuer
  # Fixed domain-separation tag prepended to every signed rental-token message.
  # The lock ONLY accepts a token if field 0 == this tag.
  CONTEXT_TAG = "kiosk-rental-v1"

  class << self
    # Issue a signed rental token.
    #
    # Charset contract: `scooter_code` and `reservation_id` MUST NOT contain the
    # field delimiter `|` (nor be split by it). The signed message packs six
    # fields pipe-delimited, and {.verify} rejects any message whose split does
    # not yield exactly 6 fields — so a `|` in either input mints a validly
    # SIGNED token that this issuer's own verifier rejects (a field-shift
    # hazard for a laxer external verifier). The skooti demo only ever passes
    # `SK-###` codes and opaque IDs with no pipe, so this is a documented input
    # precondition rather than an enforced guard.
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

    # Verify a wire token against the configured signing key.
    #
    # Splits on the LAST ".", base64url-decodes the signature, Ed25519-verifies
    # the message, checks exp >= now.
    #
    # Reference-verifier surface: the production unlock path never calls this —
    # the scooter lock (lib/lock_sim.rb / the firmware) does the verification.
    # This Ruby verifier exists solely as the known-answer-vector anchor the KAT
    # (lib/rental_token_issuer_kat.rb) runs the firmware's expected wire vector
    # through, so the byte-exact contract stays cross-checked without the lock.
    #
    # @param token [String] wire token
    # @param now   [Integer] current unix timestamp (seconds)
    # @return [Hash|nil] parsed claims hash, or nil on any failure
    def verify(token:, now:)
      return nil if token.nil? || token.empty?

      # Split on the LAST "." to separate message from signature.
      dot_idx = token.rindex(".")
      return nil if dot_idx.nil?

      message = token[0...dot_idx]
      sig_b64 = token[(dot_idx + 1)..]

      return nil if message.empty? || sig_b64.empty?

      sig = Base64.urlsafe_decode64(sig_b64)

      pub = public_key
      return nil if pub.nil?

      return nil unless pub.verify(nil, sig, message)

      fields = message.split("|")
      return nil unless fields.length == 6
      return nil unless fields[0] == CONTEXT_TAG

      _tag, scooter_code, reservation_id, iat_s, exp_s, jti = fields

      iat = Integer(iat_s, 10)
      exp = Integer(exp_s, 10)

      return nil if now > exp

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

    # The public key PEM string derived from the CONFIGURED signing key.
    #
    # KAT-anchor surface: production provisioning reads the public key from the
    # fixed dev keypair via {DevUnlockKey.public_key_pem} (see rental_flow.rb /
    # demo.rake) — that path does not depend on a configured signing key. This
    # helper derives the same value from `Kiosk.configuration.unlock_signing_key`
    # so the KAT can assert the configured-key round-trip matches the firmware
    # fixture; the two derivations are deliberately independent to cross-check.
    #
    # @return [String] PEM
    def public_key_pem
      public_key.public_to_pem
    end

    # The raw 32-byte Ed25519 public key as a lowercase hex string.
    # This is the value that gets baked into each scooter lock's firmware.
    # Ed25519 DER-encoded public key = 12-byte header + 32-byte raw key.
    #
    # KAT-anchor surface (see {.public_key_pem}): the firmware fixture is taken
    # from {DevUnlockKey.public_key_raw32_hex}; the KAT asserts this
    # configured-key derivation equals it.
    #
    # @return [String] 64 lowercase hex chars
    def public_key_raw32_hex
      der = public_key.public_to_der
      der[-32..].unpack1("H*")
    end

    private

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
