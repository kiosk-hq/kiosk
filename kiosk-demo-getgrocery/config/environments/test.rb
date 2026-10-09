# frozen_string_literal: true

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
  OpenSSL::PKey.read(File.read(File.expand_path("../../../kiosk-demo-prove/config/dev_prove_key.pem", __dir__))).public_to_pem

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = ENV["CI"].present?
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }
  config.consider_all_requests_local = true
  config.cache_store = :null_store
  config.action_dispatch.show_exceptions = :rescuable
  config.action_controller.allow_forgery_protection = false
  config.active_support.deprecation = :stderr
  config.action_controller.raise_on_missing_callback_actions = true
end

