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

  class << self
    # Issue a signed rental token.
    #
    # Charset contract: `scooter_code` and `reservation_id` MUST NOT contain the
    # field delimiter `|`. The message packs six pipe-delimited fields and
    # {.verify} rejects any split that does not yield exactly 6, so a `|` in
    # either input mints a validly SIGNED token this issuer's own verifier
    # rejects — a field-shift hazard for a laxer external verifier. skooti only
    # ever passes `SK-###` codes and pipe-free ids, so this is a documented
    # input precondition rather than an enforced guard.
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

    # Verify a wire token against the configured signing key: split on the LAST
    # ".", base64url-decode the signature, Ed25519-verify the message, check exp.
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
