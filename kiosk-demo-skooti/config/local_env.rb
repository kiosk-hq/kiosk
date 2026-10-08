# frozen_string_literal: true

# Development and test values. Production takes every one of them from the
# environment, and fails to boot without it.
require "base64"
require "openssl"

ENV["KIOSK_ISSUER"]                 ||= "http://localhost:#{ENV.fetch("PORT", "3000")}"
ENV["KIOSK_SIGNING_KEY_B64"]        ||= Base64.strict_encode64(OpenSSL::PKey::RSA.new(2048).to_pem)
ENV["KIOSK_POW_SECRET"]             ||= "skooti-local-pow-secret-not-a-secret"
ENV["STRIPE_SECRET_KEY"]            ||= "sk_test_mock"
ENV["KIOSK_PROVE_BROKER_URL"]       ||= "http://127.0.0.1:3020"
ENV["KIOSK_PROVE_ISSUER"]           ||= "http://127.0.0.1:3020"
ENV["KIOSK_PROVE_INTAKE_SECRET"]    ||= "skooti-local-intake-secret"
ENV["KIOSK_PROVE_PUBLIC_KEY_PEM"]   ||= OpenSSL::PKey::RSA.new(2048).public_key.to_pem
# The fixed dev keypair the KAT vector, the firmware fixtures and the lock simulator are pinned to.
ENV["KIOSK_UNLOCK_SIGNING_KEY_PEM"] ||= File.read(File.expand_path("dev_unlock_key.pem", __dir__))
