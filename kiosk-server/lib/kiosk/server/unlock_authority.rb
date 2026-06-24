# frozen_string_literal: true

require "openssl"

module Kiosk
  module Server
    # HMAC-SHA256 authority for offline-verifiable scooter unlock MACs.
    #
    # Key diversification model:
    #   master_key (server secret, 1 per deployment)
    #       └─► K_lock = HMAC-SHA256(master_key, scooter_id)   [32 bytes]
    #                        └─► baked into each lock at provisioning time
    #
    # Unlock MAC (returned to the App Clip / agent after a paid reservation):
    #   mac = HMAC-SHA256(K_lock, "#{scooter_id}|#{nonce_hex}|#{reservation_id}")
    #
    # The lock recomputes the same MAC from its baked K_lock + the BLE challenge
    # nonce it issued + the reservation_id received alongside the MAC, then does
    # a constant-time compare.  No server call at unlock time.
    #
    # CRITICAL — byte layout:
    #   message = scooter_id (UTF-8) + "|" + nonce_hex (lowercase ASCII) +
    #             "|" + reservation_id (UTF-8)
    #
    # This exact layout is reproduced in:
    #   - LockSim (Part B kiosk-demo-skooti)
    #   - firmware/host_test.c (Part C)
    #   - firmware/skooti_lock.ino verify_unlock() (Part C)
    # DO NOT CHANGE without updating all four sites.
    module UnlockAuthority
      module_function

      # Derive the per-lock key for `scooter_id` from the master key.
      #
      # @param scooter_id [String, #to_s]
      # @return [String] 32 raw bytes (binary encoding)
      def lock_key(scooter_id)
        master = Kiosk.configuration.unlock_master_key
        raise ArgumentError, "unlock_master_key is not configured" if master.nil?

        OpenSSL::HMAC.digest("SHA256", master, scooter_id.to_s)
      end

      # Compute the unlock authorisation MAC for one reservation + nonce pair.
      #
      # @param scooter_id     [String, #to_s]
      # @param nonce_hex      [String] 32 lowercase hex chars (16 bytes from the lock)
      # @param reservation_id [String]
      # @return [String] 64 lowercase hex characters (32-byte HMAC-SHA256)
      def mac(scooter_id:, nonce_hex:, reservation_id:)
        k = lock_key(scooter_id)
        OpenSSL::HMAC.hexdigest(
          "SHA256", k,
          "#{scooter_id}|#{nonce_hex}|#{reservation_id}",
        )
      end
    end
  end
end
