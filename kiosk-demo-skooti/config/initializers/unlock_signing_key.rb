# frozen_string_literal: true

# The Ed25519 key rental tokens are signed with; RentalTokenIssuer reads it.
Rails.application.config.x.unlock_signing_key = OpenSSL::PKey.read(ENV.fetch('KIOSK_UNLOCK_SIGNING_KEY_PEM'))
