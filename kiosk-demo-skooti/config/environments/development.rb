# frozen_string_literal: true

require "base64"
require "openssl"

ENV["KIOSK_ISSUER"]                 ||= "http://localhost:#{ENV.fetch("PORT", "3000")}"
ENV["KIOSK_SIGNING_KEY_B64"]        ||= Base64.strict_encode64(OpenSSL::PKey::RSA.new(2048).to_pem)
ENV["KIOSK_POW_SECRET"]             ||= "skooti-local-pow-secret-not-a-secret"
ENV["STRIPE_SECRET_KEY"]            ||= "sk_test_mock"
# The KYC broker kiosk-demo-prove runs locally: its URL, issuer, intake secret and signing key.
ENV["KIOSK_PROVE_BROKER_URL"]       ||= "http://127.0.0.1:3020"
ENV["KIOSK_PROVE_ISSUER"]           ||= "https://kyc.test.local"
ENV["KIOSK_PROVE_INTAKE_SECRET"]    ||= "prove-skooti-demo-shared-secret"
ENV["KIOSK_PROVE_PUBLIC_KEY_PEM"]   ||=
  OpenSSL::PKey.read(File.read(File.expand_path("../../../kiosk-demo-prove/config/dev_prove_key.pem", __dir__))).public_to_pem
# The fixed dev keypair the KAT vector, the firmware fixtures and the lock simulator are pinned to.
ENV["KIOSK_UNLOCK_SIGNING_KEY_PEM"] ||= File.read(File.expand_path("../dev_unlock_key.pem", __dir__))

Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.server_timing = true
  config.action_controller.perform_caching = false
  config.cache_store = :memory_store
  config.active_support.deprecation = :log
  config.active_record.migration_error = :page_load
  config.active_record.verbose_query_logs = true
  config.active_record.query_log_tags_enabled = true
  config.action_dispatch.verbose_redirect_logs = true
  config.action_view.annotate_rendered_view_with_filenames = true
  config.action_controller.raise_on_missing_callback_actions = true
  config.hosts << "skooti.demo.kiosk.tech"
end
