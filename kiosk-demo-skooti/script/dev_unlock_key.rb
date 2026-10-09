# frozen_string_literal: true

require "openssl"

# The fixed development and test Ed25519 rental-token keypair from
# config/dev_unlock_key.pem, for scripts and tests that run without Rails: the
# lock simulator, the firmware fixtures and the known-answer test agree on it.
# The key is public, so production refuses to boot with it.
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
