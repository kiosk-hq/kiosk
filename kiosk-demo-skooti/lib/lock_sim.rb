# frozen_string_literal: true

require "openssl"
require "rack/utils"
require "securerandom"

# Software simulator of the ESP32 BLE scooter lock firmware.
#
# The physical lock:
#   1. Bakes K_lock = HMAC-SHA256(master_key, scooter_id) at provisioning time.
#   2. On a BLE unlock request:
#      a. Issues a one-shot nonce (SecureRandom.hex(16) → 32 hex chars).
#      b. Receives (nonce_hex, reservation_id, mac) from the App Clip / agent.
#      c. Recomputes mac = HMAC-SHA256(K_lock, "scooter_id|nonce_hex|reservation_id")
#      d. Constant-time compare. On equal: unlocks + burns the nonce (one-shot).
#
# This simulator reproduces that exact logic so the agent-side driver can be
# tested without real hardware. Matches `UnlockAuthority` in kiosk-server and
# the firmware host-test vectors (Part C).
#
# CRITICAL — message layout (DO NOT CHANGE without updating all four sites):
#   message = scooter_id (UTF-8) + "|" + nonce_hex (lowercase hex) + "|" + reservation_id (UTF-8)
class LockSim
  # @param scooter_id [String]  must be the SAME string passed to UnlockAuthority.mac
  # @param lock_key   [String]  32 raw binary bytes = HMAC-SHA256(master_key, scooter_id)
  def initialize(scooter_id:, lock_key:)
    @scooter_id = scooter_id.to_s
    @lock_key   = lock_key
    @pending    = nil
    @consumed   = false
  end

  # Issue a one-shot challenge nonce. Replaces any prior pending nonce (BLE retry).
  #
  # @return [String] 32 lowercase hex characters (16 raw bytes)
  def issue_nonce
    @pending  = SecureRandom.hex(16)
    @consumed = false
    @pending
  end

  # Verify an unlock MAC presented by the agent.
  #
  # Returns +false+ if:
  #   - no nonce has been issued (nil pending)
  #   - this nonce was already consumed (replay)
  #   - the nonce doesn't match
  #   - the MAC is wrong (constant-time compare)
  # Returns +true+ and burns the nonce on success.
  #
  # @param nonce_hex      [String] the nonce originally issued by #issue_nonce
  # @param reservation_id [String]
  # @param mac            [String] 64 lowercase hex chars from UnlockAuthority
  # @return [Boolean]
  def unlock(nonce_hex:, reservation_id:, mac:)
    return false if @pending.nil?
    return false if @consumed
    return false unless nonce_hex == @pending

    expected = OpenSSL::HMAC.hexdigest(
      "SHA256",
      @lock_key,
      "#{@scooter_id}|#{nonce_hex}|#{reservation_id}",
    )

    # Constant-time compare — mirrors the firmware's mbedtls_ssl_safer_memcmp.
    # Rack::Utils.secure_compare is available (Rack is always in the bundle).
    return false unless Rack::Utils.secure_compare(expected, mac.to_s)

    @consumed = true
    true
  end
end
