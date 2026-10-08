# frozen_string_literal: true

# Development and test values. Production takes every one of them from the
# environment, and fails to boot without it.
require "base64"
require "openssl"

ENV["KIOSK_ISSUER"]          ||= "http://localhost:#{ENV.fetch("PORT", "3000")}"
ENV["KIOSK_SIGNING_KEY_B64"] ||= Base64.strict_encode64(OpenSSL::PKey::RSA.new(2048).to_pem)
ENV["KIOSK_POW_SECRET"]      ||= "atablefor-local-pow-secret-not-a-secret"
