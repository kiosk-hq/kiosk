# frozen_string_literal: true

require "openssl"
require "base64"
require "securerandom"

module Kiosk
  module Server
    # Ed25519 offline rental-token authority (Arch 2).
    #
    # The scooter verifies the signed rental token itself — no server round-trip
    # at unlock time.  Skooti signs with its Ed25519 private key; the public key
    # is baked into every lock at provisioning time.
    #
    # Canonical token wire format (split on the LAST "."):
    #   "<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>.<base64url(sig)>"
    #
    # Signed message (UTF-8, exact bytes):
    #   "<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>"
    #   where iat/exp are unix seconds as decimal strings,
    #   and jti = SecureRandom.hex(16)  (32 lowercase hex chars).
    #
    # Signature: Ed25519 over the message bytes (64 bytes, deterministic).
    # Crypto: OpenSSL::PKey Ed25519 — key.sign(nil, message) / key.verify(nil, sig, msg).
    #
    # This exact format is reproduced (byte-identical) in:
    #   - kiosk-demo-skooti LockSim  (T2)
    #   - firmware/host_test.c       (T3)
    #   - firmware/skooti_lock.ino   (T3)
    # DO NOT CHANGE without updating all sites and re-recording the known-answer vector.
    module RentalTokenIssuer
      class << self
        # Issue a signed rental token.
        #
        # @param scooter_code   [String]  e.g. "SK-001"
        # @param reservation_id [String]  UUID or other opaque ID
        # @param now            [Integer] current unix timestamp (seconds)
        # @param ttl            [Integer] token lifetime in seconds (default 900 = 15 min)
        # @return [String] wire token: "<message>.<base64url_sig>"
        def issue(scooter_code:, reservation_id:, now:, ttl: 900)
          key = signing_key
          raise ArgumentError, "unlock_signing_key is not configured" if key.nil?

          iat     = now
          exp     = iat + ttl
          jti     = SecureRandom.hex(16)
          message = "#{scooter_code}|#{reservation_id}|#{iat}|#{exp}|#{jti}"
          sig     = key.sign(nil, message)
          "#{message}.#{Base64.urlsafe_encode64(sig, padding: false)}"
        end

        # Verify a wire token against the configured signing key.
        #
        # Splits on the LAST ".", base64url-decodes the signature, Ed25519-verifies
        # the message, checks exp >= now.
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
          return nil unless fields.length == 5

          scooter_code, reservation_id, iat_s, exp_s, jti = fields

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

        # The public key PEM string derived from the configured signing key.
        #
        # @return [String] PEM
        def public_key_pem
          public_key.public_to_pem
        end

        # The raw 32-byte Ed25519 public key as a lowercase hex string.
        # This is the value that gets baked into each scooter lock's firmware.
        # Ed25519 DER-encoded public key = 12-byte header + 32-byte raw key.
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
  end
end
