# frozen_string_literal: true

require "openssl"
require "base64"
require "securerandom"

# Signs the offline rental token a scooter lock verifies with no round trip,
# and verifies it the way the lock does. The grammar is RENTAL_TOKEN.md;
# script/lock_sim.rb and the firmware read the same bytes, and
# `cd firmware && make crosscheck` holds all three to one answer.
#
#   kiosk-rental-v1|<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>.<base64url Ed25519 signature>
module RentalTokenIssuer
  # Field 0: the lock accepts nothing else, so the key signs nothing else.
  CONTEXT_TAG = "kiosk-rental-v1"

  # The lock's limits (firmware/verify.h).
  TOKEN_MAX_BYTES = 512

  SIG_B64_MAX = 88

  # Unpadded base64url only: Base64.urlsafe_decode64 also accepts "+/" and "=".
  SIG_B64_FORMAT = /\A[A-Za-z0-9\-_]+\z/

  # The lock reads a C string, so a NUL ends the token there.
  NUL_BYTE = "\u0000".b

  FIELD_COUNT = 6
  DELIMITER   = "|"

  # What the lock's parse_uint64 accepts; Integer() would also take signs and underscores.
  TIMESTAMP_FORMAT = /\A[0-9]{1,20}\z/
  TIMESTAMP_MAX    = (1 << 64) - 1

  JTI_FORMAT = /\A[0-9a-f]{32}\z/

  # scooter_code and reservation_id: RFC 3986 unreserved characters, small
  # enough that every byte value is tested against all three readers.
  FIELD_CHARSET = /\A[A-Za-z0-9._~-]+\z/

  class << self
    # Refuses a field outside FIELD_CHARSET rather than sign a token every reader rejects.
    def issue(scooter_code:, reservation_id:, now:, ttl: 900)
      key = signing_key
      raise ArgumentError, "unlock_signing_key is not configured" if key.nil?

      unless scooter_code.to_s.b.match?(FIELD_CHARSET)
        raise ArgumentError, "scooter_code must be 1+ characters of A-Za-z0-9._~-"
      end
      unless reservation_id.to_s.b.match?(FIELD_CHARSET)
        raise ArgumentError, "reservation_id must be 1+ characters of A-Za-z0-9._~-"
      end

      iat     = now
      exp     = iat + ttl
      jti     = SecureRandom.hex(16)
      message = "#{CONTEXT_TAG}|#{scooter_code}|#{reservation_id}|#{iat}|#{exp}|#{jti}"
      sig     = key.sign(nil, message)
      "#{message}.#{Base64.urlsafe_encode64(sig, padding: false)}"
    end

    # The claims, or nil for anything the lock would refuse. It reads bytes,
    # as the lock does, so the caller's encoding tag cannot change the answer.
    def verify(token:, now:)
      return nil if token.nil?

      token = token.to_s.b
      return nil if token.empty?
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

      # -1 keeps a trailing empty field, which the lock counts.
      fields = message.split(DELIMITER, -1)
      return nil unless fields.length == FIELD_COUNT
      return nil if fields.any?(&:empty?)
      return nil unless fields[0] == CONTEXT_TAG.b

      _tag, scooter_code, reservation_id, iat_s, exp_s, jti = fields

      return nil unless scooter_code.match?(FIELD_CHARSET)
      return nil unless reservation_id.match?(FIELD_CHARSET)

      return nil unless timestamp?(iat_s)
      return nil unless timestamp?(exp_s)
      return nil unless jti.match?(JTI_FORMAT)

      iat = Integer(iat_s, 10)
      exp = Integer(exp_s, 10)

      return nil unless exp > now

      {
        scooter_code:   scooter_code.force_encoding(Encoding::UTF_8),
        reservation_id: reservation_id.force_encoding(Encoding::UTF_8),
        iat:            iat,
        exp:            exp,
        jti:            jti.force_encoding(Encoding::UTF_8),
      }
    rescue ArgumentError, OpenSSL::PKey::PKeyError
      nil
    end

    def public_key_pem
      public_key.public_to_pem
    end

    # The 32 raw key bytes a lock is provisioned with: the tail of the DER encoding.
    def public_key_raw32_hex
      der = public_key.public_to_der
      der[-32..].unpack1("H*")
    end

    private

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
