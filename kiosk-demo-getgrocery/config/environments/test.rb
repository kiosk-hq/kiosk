# frozen_string_literal: true

require 'base64'
require 'openssl'
require 'kiosk/test_helpers/small_equihash'
require 'kiosk/test_helpers/stripe_mock'

ENV['KIOSK_ISSUER']                 ||= "http://localhost:#{ENV.fetch('PORT', '3000')}"
ENV['KIOSK_SIGNING_KEY_B64']        ||= Base64.strict_encode64(OpenSSL::PKey.generate_key('ED25519').private_to_pem)
ENV['KIOSK_POW_SECRET']             ||= 'getgrocery-local-pow-secret-not-a-secret'
ENV['STRIPE_SECRET_KEY']            ||= 'sk_test_mock'
ENV['STRIPE_MOCK_URL']              ||= Kiosk::TestHelpers::StripeMock.url
# The KYC broker kiosk-demo-proveli runs locally: its URL, issuer, intake secret and signing key.
ENV['KIOSK_PROVELI_BROKER_URL']     ||= 'http://127.0.0.1:3020'
ENV['KIOSK_PROVELI_ISSUER']         ||= 'https://kyc.test.local'
ENV['KIOSK_PROVELI_INTAKE_SECRET']  ||= 'proveli-getgrocery-demo-shared-secret'
ENV['KIOSK_PROVELI_PUBLIC_KEY_PEM'] ||=
  OpenSSL::PKey.read(File.read(File.expand_path('../../../kiosk-demo-proveli/config/dev_proveli_key.pem', __dir__))).public_to_pem

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = ENV['CI'].present?
  config.public_file_server.headers = { 'cache-control' => 'public, max-age=3600' }
  config.consider_all_requests_local = true
  config.cache_store = :null_store
  config.action_dispatch.show_exceptions = :rescuable
  config.action_controller.allow_forgery_protection = false
  config.active_support.deprecation = :stderr
  config.action_controller.raise_on_missing_callback_actions = true
end
