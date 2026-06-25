# frozen_string_literal: true

require "openssl"

# Fixed dev Ed25519 keypair for the skooti demo. The private key is used
# by Kiosk.configuration.unlock_signing_key to sign rental tokens; the
# public key is baked into the scooter lock firmware.
#
# This is intentionally a fixed, hard-coded keypair so that:
#   1. Rental token signatures are stable across process restarts.
#   2. Test vectors (known-answer) reproduce exactly.
#   3. The firmware host-test (T3) can hard-code the public key.
#
# In production / real deployments:
#   - Replace DEV_PRIVATE_PEM with a PEM loaded from an env var / secrets manager.
#   - Never commit a production private key to source control.
#
# DevUnlockKey.private_key  → OpenSSL::PKey::PKey (Ed25519, private)
# DevUnlockKey.public_key_pem  → PEM string (configure c.unlock_signing_key = DevUnlockKey.private_key)
# DevUnlockKey.public_key_raw32_hex → 64-char hex (the 32 bytes baked into firmware)
#
# Keypair generated once:
#   ruby -ropenssl -e "k=OpenSSL::PKey.generate_key('ED25519'); puts k.private_to_pem"
# DO NOT use in production.
class DevUnlockKey
  # Fixed dev Ed25519 private key — stable for the skooti demo.
  # DO NOT use in production.
  DEV_PRIVATE_PEM = <<~PEM.freeze
    -----BEGIN PRIVATE KEY-----
    MC4CAQAwBQYDK2VwBCIEINeFKJGXag/XX62rnmCiS2NKnbvRliRBDuuTbrxQ/n3R
    -----END PRIVATE KEY-----
  PEM

  KEYPAIR = OpenSSL::PKey.read(DEV_PRIVATE_PEM)
  private_constant :KEYPAIR

  # The Ed25519 private key — set as Kiosk.configuration.unlock_signing_key.
  def self.private_key
    KEYPAIR
  end

  # The Ed25519 public key PEM string.
  def self.public_key_pem
    KEYPAIR.public_to_pem
  end

  # The raw 32-byte Ed25519 public key as a lowercase hex string.
  # Ed25519 DER = 12-byte header + 32-byte raw key.
  # This is the value baked into each scooter lock firmware.
  def self.public_key_raw32_hex
    der = OpenSSL::PKey.read(KEYPAIR.public_to_pem).public_to_der
    der[-32..].unpack1("H*")
  end
end
