# frozen_string_literal: true

require "openssl"

# The public development Ed25519 rental-token keypair (config/dev_unlock_key.pem), for
# scripts and tests that run without Rails; production refuses to boot with it.
class DevUnlockKey
  PEM_PATH = File.expand_path("../config/dev_unlock_key.pem", __dir__)

  # Read on first use: a production eager-load must not open the dev key file.
  def self.keypair
    @keypair ||= OpenSSL::PKey.read(File.read(PEM_PATH))
  end

  def self.private_key
    keypair
  end

  def self.public_key_pem
    keypair.public_to_pem
  end

  # The 32 raw key bytes baked into the lock firmware (DER is a 12-byte header + the key).
  def self.public_key_raw32_hex
    der = OpenSSL::PKey.read(keypair.public_to_pem).public_to_der
    der[-32..].unpack1("H*")
  end
end
