# frozen_string_literal: true

require 'openssl'
require 'base64'

# Software simulator of the ESP32 BLE scooter lock firmware: offline Ed25519 verify of
# the rental token, byte for byte the grammar of RENTAL_TOKEN.md and firmware/verify.c,
# with an in-memory jti store that, like the lock, is empty again after a restart.

LOCK_SIM_CONTEXT_TAG = 'kiosk-rental-v1'

# Limits are the firmware's own (firmware/verify.c).
LOCK_SIM_TOKEN_MAX_BYTES  = 512
LOCK_SIM_SIG_B64_MAX      = 88
# Unpadded base64url only: urlsafe_decode64 alone would accept "+/" and "=".
LOCK_SIM_SIG_B64_FORMAT   = /\A[A-Za-z0-9\-_]+\z/
# The lock reads a NUL-terminated C string, so a NUL ends the token it sees.
LOCK_SIM_NUL_BYTE         = "\u0000".b
LOCK_SIM_FIELD_COUNT      = 6
LOCK_SIM_DELIMITER        = '|'
LOCK_SIM_TIMESTAMP_FORMAT = /\A[0-9]{1,20}\z/
LOCK_SIM_TIMESTAMP_MAX    = (1 << 64) - 1
LOCK_SIM_JTI_FORMAT       = /\A[0-9a-f]{32}\z/
# scooter_code and reservation_id: the RFC 3986 unreserved set (firmware is_unreserved()).
LOCK_SIM_FIELD_CHARSET    = /\A[A-Za-z0-9._~-]+\z/

class LockSim
  # Ed25519 SubjectPublicKeyInfo DER header.
  ED25519_DER_HEADER = "\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00"

  # skooti_public_key: an OpenSSL Ed25519 key, or its 32 raw bytes, or their hex.
  def initialize(scooter_code:, skooti_public_key:)
    @scooter_code = scooter_code.to_s
    @pub_key = read_public_key(skooti_public_key)
    # jti => exp
    @consumed_jtis = {}
  end

  # True, consuming the jti, only for a well-formed, signed, fresh, unreplayed token for this lock.
  def unlock(token:, now:)
    message = signed_message(token)
    return false if message.nil?

    fields = token_fields(message)
    return false if fields.nil?

    first_use?(fields.last, Integer(fields[4], 10), now)
  rescue ArgumentError, OpenSSL::PKey::PKeyError
    false
  end

  private

  def read_public_key(key)
    case key
    when OpenSSL::PKey::PKey
      key
    when String
      raw = key.length == 32 ? key : [key].pack('H*')
      OpenSSL::PKey.read(ED25519_DER_HEADER + raw)
    else
      raise ArgumentError, 'skooti_public_key must be an OpenSSL::PKey::PKey or a 32-byte String'
    end
  end

  # The signed part of the token, or nil when the token is malformed or the signature is bad.
  def signed_message(token)
    return nil if token.nil?

    # Bytes, not characters: the verdict must not depend on the caller's encoding tag.
    token = token.to_s.b
    return nil unless token_envelope?(token)

    dot_idx = token.rindex('.')
    message = token[0...dot_idx]
    sig_b64 = token[(dot_idx + 1)..]
    message if signature_valid?(message, sig_b64)
  end

  def token_envelope?(token)
    return false if token.empty?
    return false if token.bytesize > LOCK_SIM_TOKEN_MAX_BYTES
    return false if token.include?(LOCK_SIM_NUL_BYTE)

    !token.rindex('.').nil?
  end

  def signature_valid?(message, sig_b64)
    return false if message.empty? || sig_b64.empty?
    return false if sig_b64.bytesize > LOCK_SIM_SIG_B64_MAX
    return false unless sig_b64.match?(LOCK_SIM_SIG_B64_FORMAT)

    sig = Base64.urlsafe_decode64(sig_b64)
    return false if sig.bytesize != 64

    # nil digest: pure EdDSA.
    @pub_key.verify(nil, sig, message)
  end

  # The six fields of a message for this lock, or nil when any field breaks the grammar.
  def token_fields(message)
    # Limit -1 keeps trailing empty fields, which the lock refuses.
    fields = message.split(LOCK_SIM_DELIMITER, -1)
    return nil unless fields.length == LOCK_SIM_FIELD_COUNT
    return nil if fields.any?(&:empty?)

    fields if fields_valid?(fields)
  end

  def fields_valid?(fields)
    context_tag, token_scooter, reservation_id, iat_s, exp_s, jti = fields
    context_tag == LOCK_SIM_CONTEXT_TAG.b &&
      token_scooter == @scooter_code &&
      token_scooter.match?(LOCK_SIM_FIELD_CHARSET) &&
      reservation_id.match?(LOCK_SIM_FIELD_CHARSET) &&
      lock_sim_timestamp?(iat_s) && lock_sim_timestamp?(exp_s) &&
      jti.match?(LOCK_SIM_JTI_FORMAT)
  end

  # True, and the jti is recorded, when the token is fresh and its jti is unused.
  def first_use?(jti, exp, now)
    return false unless exp > now

    @consumed_jtis.delete_if { |_j, stored_exp| stored_exp < now }
    return false if @consumed_jtis.key?(jti) && @consumed_jtis[jti] >= now

    @consumed_jtis[jti] = exp
    true
  end

  # 1-20 plain digits up to UINT64_MAX, as the firmware's parse_uint64; Integer() alone takes signs and "_".
  def lock_sim_timestamp?(text)
    return false unless text.match?(LOCK_SIM_TIMESTAMP_FORMAT)

    Integer(text, 10) <= LOCK_SIM_TIMESTAMP_MAX
  end
end
