# frozen_string_literal: true

require 'openssl'
require 'base64'
require 'securerandom'

# Signs the offline rental token a scooter lock verifies with no round trip,
# and verifies it the way the lock does. The grammar is RENTAL_TOKEN.md;
# script/lock_sim.rb and the firmware read the same bytes, and
# `cd firmware && make crosscheck` holds all three to one answer.
#
#   kiosk-rental-v1|<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>.<base64url Ed25519 signature>
module RentalTokenIssuer
  # Field 0: the lock accepts nothing else, so the key signs nothing else.
  CONTEXT_TAG = 'kiosk-rental-v1'

  # The lock's limits (firmware/verify.h).
  TOKEN_MAX_BYTES = 512

  SIG_B64_MAX = 88

  # Unpadded base64url only: Base64.urlsafe_decode64 also accepts "+/" and "=".
  SIG_B64_FORMAT = /\A[A-Za-z0-9\-_]+\z/

  # The lock reads a C string, so a NUL ends the token there.
  NUL_BYTE = "\u0000".b

  FIELD_COUNT = 6
  DELIMITER   = '|'

  # What the lock's parse_uint64 accepts; Integer() would also take signs and underscores.
  TIMESTAMP_FORMAT = /\A[0-9]{1,20}\z/
  TIMESTAMP_MAX    = (1 << 64) - 1

  JTI_FORMAT = /\A[0-9a-f]{32}\z/
  TTL        = 900

  # scooter_code and reservation_id: RFC 3986 unreserved characters, small
  # enough that every byte value is tested against all three readers.
  FIELD_CHARSET = /\A[A-Za-z0-9._~-]+\z/

  class << self
    # Refuses a field outside FIELD_CHARSET rather than sign a token every reader rejects.
    def issue(scooter_code:, reservation_id:, now:)
      key = signing_key
      raise ArgumentError, 'unlock_signing_key is not configured' if key.nil?

      raise ArgumentError, 'scooter_code must be 1+ characters of A-Za-z0-9._~-' unless scooter_code.to_s.b.match?(FIELD_CHARSET)
      raise ArgumentError, 'reservation_id must be 1+ characters of A-Za-z0-9._~-' unless reservation_id.to_s.b.match?(FIELD_CHARSET)

      iat     = now
      exp     = iat + TTL
      jti     = SecureRandom.hex(16)
      message = "#{CONTEXT_TAG}|#{scooter_code}|#{reservation_id}|#{iat}|#{exp}|#{jti}"
      sig     = key.sign(nil, message)
      "#{message}.#{Base64.urlsafe_encode64(sig, padding: false)}"
    end

    # The claims, or nil for anything the lock would refuse. It reads bytes,
    # as the lock does, so the caller's encoding tag cannot change the answer.
    def verify(token:, now:)
      message, sig = signed_parts(token.to_s.b)
      return nil unless message && authentic?(message, sig)

      claims = claims_in(message)
      claims if claims && claims[:exp] > now
    rescue ArgumentError, OpenSSL::PKey::PKeyError
      nil
    end

    private

    # The message and the decoded signature, or nil when the envelope is malformed.
    def signed_parts(token)
      return nil unless envelope?(token)

      message, _dot, sig_b64 = token.rpartition('.')
      return nil if message.empty? || !signature_text?(sig_b64)

      sig = Base64.urlsafe_decode64(sig_b64)
      [message, sig] if sig.bytesize == 64
    end

    def envelope?(token) = !token.empty? && token.bytesize <= TOKEN_MAX_BYTES && !token.include?(NUL_BYTE)

    def signature_text?(sig_b64) = sig_b64.bytesize <= SIG_B64_MAX && sig_b64.match?(SIG_B64_FORMAT)

    def authentic?(message, sig)
      pub = public_key
      !pub.nil? && pub.verify(nil, sig, message)
    end

    # The claims of a well-formed message, or nil.
    def claims_in(message)
      # -1 keeps a trailing empty field, which the lock counts.
      fields = message.split(DELIMITER, -1)
      return nil unless fields_valid?(fields)

      _tag, scooter_code, reservation_id, iat, exp, jti = fields
      { scooter_code: utf8(scooter_code), reservation_id: utf8(reservation_id),
        iat: Integer(iat, 10), exp: Integer(exp, 10), jti: utf8(jti) }
    end

    def fields_valid?(fields)
      return false unless fields.length == FIELD_COUNT && fields[0] == CONTEXT_TAG.b

      _tag, scooter_code, reservation_id, iat, exp, jti = fields
      [scooter_code, reservation_id].all? { it.match?(FIELD_CHARSET) } &&
        [iat, exp].all? { timestamp?(it) } && jti.match?(JTI_FORMAT)
    end

    def utf8(bytes) = bytes.force_encoding(Encoding::UTF_8)

    def timestamp?(text)
      return false unless text.match?(TIMESTAMP_FORMAT)

      Integer(text, 10) <= TIMESTAMP_MAX
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
