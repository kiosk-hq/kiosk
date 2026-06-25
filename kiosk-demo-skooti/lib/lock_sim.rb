# frozen_string_literal: true

require "openssl"
require "base64"

# Software simulator of the ESP32 BLE scooter lock firmware (Arch 2 — Ed25519, token v2).
#
# The physical lock (Arch 2):
#   1. Baked at provisioning with:
#      - the skooti Ed25519 PUBLIC key (32 bytes)
#      - its own SCOOTER_CODE
#   2. On a BLE unlock request it receives the wire rental token (v2):
#        "kiosk-rental-v1|<scooter_code>|<reservation_id>|<iat>|<exp>|<jti>.<base64url(sig)>"
#      a. Splits on the LAST "."
#      b. Base64url-decodes the sig (64 bytes)
#      c. Ed25519-verifies the sig over the message bytes
#      d. Parses the 6 pipe-separated fields
#      e. Checks: field 0 == "kiosk-rental-v1" (domain-separation tag)
#      f. Checks: scooter_code == own code, exp > now (injected clock)
#      g. Checks jti NOT in the consumed store (durable replay prevention)
#      h. On all checks passing: records jti → exp in the consumed store, unlocks
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
# NO HMAC, no nonce/challenge — those are Arch-1 concepts and are gone.

LOCK_SIM_CONTEXT_TAG = "kiosk-rental-v1"

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

  # Verify and consume a rental token (v2 — domain-separation tag + durable replay prevention).
  #
  # Returns +false+ if:
  #   - token is malformed or base64url-decode fails
  #   - Ed25519 signature is invalid
  #   - field 0 != "kiosk-rental-v1" (wrong or missing domain-separation tag)
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

    # Parse the 6 pipe-delimited fields (v2: field 0 is the domain-separation tag).
    fields = message.split("|")
    return false unless fields.length == 6

    context_tag, token_scooter, _reservation_id, _iat_s, exp_s, jti = fields

    # Gate: domain-separation — field 0 must be the known context tag.
    return false unless context_tag == LOCK_SIM_CONTEXT_TAG

    # Gate: scooter code must match what this lock is provisioned with.
    return false unless token_scooter == @scooter_code

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
end
