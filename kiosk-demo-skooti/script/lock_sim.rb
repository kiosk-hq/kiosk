# frozen_string_literal: true

require "openssl"
require "base64"

# Software simulator of the ESP32 BLE scooter lock firmware: offline Ed25519 verify of
# the rental token, byte for byte the grammar of RENTAL_TOKEN.md and firmware/verify.c,
# with an in-memory jti store that, like the lock, is empty again after a restart.

LOCK_SIM_CONTEXT_TAG = "kiosk-rental-v1"

# Limits are the firmware's own (firmware/verify.c).
LOCK_SIM_TOKEN_MAX_BYTES  = 512
LOCK_SIM_SIG_B64_MAX      = 88
# Unpadded base64url only: urlsafe_decode64 alone would accept "+/" and "=".
LOCK_SIM_SIG_B64_FORMAT   = /\A[A-Za-z0-9\-_]+\z/
# The lock reads a NUL-terminated C string, so a NUL ends the token it sees.
LOCK_SIM_NUL_BYTE         = "\u0000".b
LOCK_SIM_FIELD_COUNT      = 6
LOCK_SIM_DELIMITER        = "|"
LOCK_SIM_TIMESTAMP_FORMAT = /\A[0-9]{1,20}\z/
LOCK_SIM_TIMESTAMP_MAX    = (1 << 64) - 1
LOCK_SIM_JTI_FORMAT       = /\A[0-9a-f]{32}\z/
# scooter_code and reservation_id: the RFC 3986 unreserved set (firmware is_unreserved()).
LOCK_SIM_FIELD_CHARSET    = /\A[A-Za-z0-9._~-]+\z/

class LockSim
  # skooti_public_key: an OpenSSL Ed25519 key, or its 32 raw bytes, or their hex.
  def initialize(scooter_code:, skooti_public_key:)
    @scooter_code = scooter_code.to_s

    @pub_key = case skooti_public_key
               when OpenSSL::PKey::PKey
                 skooti_public_key
               when String
                 raw = skooti_public_key.length == 32 ? skooti_public_key : [skooti_public_key].pack("H*")
                 # Ed25519 SubjectPublicKeyInfo DER header.
                 header = "\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00"
                 der    = header + raw
                 OpenSSL::PKey.read(der)
               else
                 raise ArgumentError, "skooti_public_key must be an OpenSSL::PKey::PKey or a 32-byte String"
               end

    # jti => exp
    @consumed_jtis = {}
  end

  # True, consuming the jti, only for a well-formed, signed, fresh, unreplayed token for this lock.
  def unlock(token:, now:)
    return false if token.nil?

    # Bytes, not characters: the verdict must not depend on the caller's encoding tag.
    token = token.to_s.b
    return false if token.empty?

    return false if token.bytesize > LOCK_SIM_TOKEN_MAX_BYTES

    return false if token.b.include?(LOCK_SIM_NUL_BYTE)

    dot_idx = token.rindex(".")
    return false if dot_idx.nil?

    message = token[0...dot_idx]
    sig_b64 = token[(dot_idx + 1)..]

    return false if message.empty? || sig_b64.empty?
    return false if sig_b64.bytesize > LOCK_SIM_SIG_B64_MAX
    return false unless sig_b64.match?(LOCK_SIM_SIG_B64_FORMAT)

    sig = Base64.urlsafe_decode64(sig_b64)
    return false if sig.bytesize != 64

    # nil digest: pure EdDSA.
    return false unless @pub_key.verify(nil, sig, message)

    # Limit -1 keeps trailing empty fields, which the lock refuses.
    fields = message.split(LOCK_SIM_DELIMITER, -1)
    return false unless fields.length == LOCK_SIM_FIELD_COUNT
    return false if fields.any?(&:empty?)

    context_tag, token_scooter, reservation_id, iat_s, exp_s, jti = fields

    return false unless context_tag == LOCK_SIM_CONTEXT_TAG.b

    return false unless token_scooter == @scooter_code

    return false unless token_scooter.match?(LOCK_SIM_FIELD_CHARSET)
    return false unless reservation_id.match?(LOCK_SIM_FIELD_CHARSET)

    return false unless lock_sim_timestamp?(iat_s)
    return false unless lock_sim_timestamp?(exp_s)
    return false unless jti.match?(LOCK_SIM_JTI_FORMAT)

    exp = Integer(exp_s, 10)
    return false unless exp > now

    @consumed_jtis.delete_if { |_j, stored_exp| stored_exp < now }

    if @consumed_jtis.key?(jti) && @consumed_jtis[jti] >= now
      return false
    end

    @consumed_jtis[jti] = exp
    true
  rescue ArgumentError, OpenSSL::PKey::PKeyError
    false
  end

  private

  # 1-20 plain digits up to UINT64_MAX, as the firmware's parse_uint64; Integer() alone takes signs and "_".
  def lock_sim_timestamp?(s)
    return false unless s.match?(LOCK_SIM_TIMESTAMP_FORMAT)

    Integer(s, 10) <= LOCK_SIM_TIMESTAMP_MAX
  end
end
