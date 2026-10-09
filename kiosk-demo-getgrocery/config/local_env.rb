# frozen_string_literal: true

# Development and test values. Production takes every one of them from the
# environment, and fails to boot without it.
require "base64"
require "openssl"

ENV["KIOSK_ISSUER"]               ||= "http://localhost:#{ENV.fetch("PORT", "3000")}"
ENV["KIOSK_SIGNING_KEY_B64"]      ||= Base64.strict_encode64(OpenSSL::PKey::RSA.new(2048).to_pem)
ENV["KIOSK_POW_SECRET"]           ||= "getgrocery-local-pow-secret-not-a-secret"
ENV["STRIPE_SECRET_KEY"]          ||= "sk_test_mock"
# The KYC broker kiosk-demo-prove runs locally: its URL, issuer, intake secret and signing key.
ENV["KIOSK_PROVE_BROKER_URL"]     ||= "http://127.0.0.1:3020"
ENV["KIOSK_PROVE_ISSUER"]         ||= "https://kyc.test.local"
ENV["KIOSK_PROVE_INTAKE_SECRET"]  ||= "prove-getgrocery-demo-shared-secret"
ENV["KIOSK_PROVE_PUBLIC_KEY_PEM"] ||=
  OpenSSL::PKey.read(File.read(File.expand_path("../../kiosk-demo-prove/config/dev_prove_key.pem", __dir__))).public_to_pem
