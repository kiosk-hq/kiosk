# frozen_string_literal: true

require "openssl"
require "base64"

# Software simulator of the ESP32 BLE scooter lock firmware (Arch 2 — Ed25519).
#
# The physical lock (Arch 2):
#   1. Baked at provisioning with:
#      - the skooti Ed25519 PUBLIC key (32 bytes)
#      - its own SCOOTER_CODE
#   2. On a BLE unlock request it receives the wire rental token:
#        "<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>.<base64url(sig)>"
#      a. Splits on the LAST "."
#      b. Base64url-decodes the sig (64 bytes)
#      c. Ed25519-verifies the sig over the message bytes
#      d. Parses the 5 pipe-separated fields
#      e. Checks: scooter_code == own code, exp > now (injected clock)
#      f. Checks jti NOT in the consumed set (one-shot anti-replay)
#      g. On all checks passing: adds jti to the consumed set, unlocks
#
# This simulator reproduces that exact logic so the agent-side driver can be
# tested without real hardware.
#
# NO HMAC, no nonce/challenge — those are Arch-1 concepts and are gone.
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

    @consumed_jtis = {}
  end

  # Verify and consume a rental token.
  #
  # Returns +false+ if:
  #   - token is malformed or base64url-decode fails
  #   - Ed25519 signature is invalid
  #   - scooter_code in the token does not match this lock's code
  #   - exp <= now  (expired)
  #   - jti was already consumed (replay)
  # Returns +true+ and records the jti on success (one-shot).
  #
  # @param token [String]  wire token: "<message>.<base64url(sig)>"
  # @param now   [Integer] current unix timestamp (seconds), injected for testing
  # @return [Boolean]
  def unlock(token:, now:)
    return false if token.nil? || token.empty?

    # Split on the LAST "." — the message itself contains "|" but no ".".
    dot_idx = token.rindex(".")
    return false if dot_idx.nil?

    message = token[0...dot_idx]
    sig_b64 = token[(dot_idx + 1)..]

    return false if message.empty? || sig_b64.empty?

    # Decode sig — base64url, no padding.
    sig = Base64.urlsafe_decode64(sig_b64)
    return false if sig.bytesize != 64

    # Ed25519-verify: OpenSSL's verify(nil, sig, msg) — nil digest = pure EdDSA.
    return false unless @pub_key.verify(nil, sig, message)

    # Parse the 5 pipe-delimited fields.
    fields = message.split("|")
    return false unless fields.length == 5

    token_scooter, _reservation_id, _iat_s, exp_s, jti = fields

    # Gate: scooter code must match what this lock is provisioned with.
    return false unless token_scooter == @scooter_code

    # Gate: freshness — exp must be strictly greater than now.
    exp = Integer(exp_s, 10)
    return false unless exp > now

    # Gate: one-shot anti-replay — jti must not have been consumed.
    return false if @consumed_jtis.key?(jti)

    # All checks passed — consume the jti and unlock.
    @consumed_jtis[jti] = true
    true
  rescue ArgumentError, OpenSSL::PKey::PKeyError
    false
  end
end
