# frozen_string_literal: true

require "openssl"

# The FIXED DEV/TEST Ed25519 rental-token keypair, read from
# config/dev_unlock_key.pem. The private half signs rental tokens in
# development and test; the public half is what the lock simulator and the
# firmware host-test verify against.
#
# It is a fixed keypair (not per-boot ephemeral) so that:
#   1. Rental token signatures are stable across process restarts.
#   2. The known-answer vector (script/rental_token_issuer_kat.rb) reproduces exactly.
#   3. The firmware host-test (firmware/host_test.c) can hard-code the public key.
#
# DEV/TEST ONLY. The private half ships world-readable in this public
# repo, so it is NOT a key anything real may sign with: production refuses to
# boot with it. The server reads KIOSK_UNLOCK_SIGNING_KEY_PEM, never this class.
#
# WHY IT EXISTS AS A CLASS OF ITS OWN, and why it deliberately does NOT read
# Rails config: its callers are
# BARE-RUBY drivers with no Rails at all — script/rental_flow.rb and
# script/kyc_flow.rb provision their LockSim with the dev public half, and
# script/rental_token_issuer_kat.rb signs with the dev private half. Reaching for
# Rails.configuration here would make all three die outside a booted app.
#
# DevUnlockKey.private_key         → OpenSSL::PKey::PKey (Ed25519, private)
# DevUnlockKey.public_key_pem      → PEM string
# DevUnlockKey.public_key_raw32_hex → 64-char hex (the 32 bytes baked into firmware)
class DevUnlockKey
  # The same key the development and test servers sign with.
  PEM_PATH = File.expand_path("../config/dev_unlock_key.pem", __dir__)

  # Read on FIRST USE, not at class-definition time. Production eager-loads
  # every lib/ constant (config.autoload_lib), and a production boot has no
  # business so much as opening the dev key file — nothing there wires it.
  def self.keypair
    @keypair ||= OpenSSL::PKey.read(File.read(PEM_PATH))
  end

  # The Ed25519 private key — dev/test only (see the header).
  def self.private_key
    keypair
  end

  # The Ed25519 public key PEM string.
  def self.public_key_pem
    keypair.public_to_pem
  end

  # The raw 32-byte Ed25519 public key as a lowercase hex string.
  # Ed25519 DER = 12-byte header + 32-byte raw key.
  # This is the value baked into each dev scooter lock firmware.
  def self.public_key_raw32_hex
    der = OpenSSL::PKey.read(keypair.public_to_pem).public_to_der
    der[-32..].unpack1("H*")
  end
end
