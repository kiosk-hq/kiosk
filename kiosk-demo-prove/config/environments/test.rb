require "openssl"

# The KYC broker as the local operator demos expect it: their issuer, their intake
# secrets, callbacks on loopback, and the development signing key.
ENV["KIOSK_PROVE_ISSUER"]                   ||= "https://kyc.test.local"
ENV["KIOSK_PROVE_SKOOTI_SECRET"]            ||= "prove-skooti-test-intake-secret"
ENV["KIOSK_PROVE_GETGROCERY_SECRET"]        ||= "prove-getgrocery-test-intake-secret"
ENV["KIOSK_PROVE_SKOOTI_CALLBACK_HOST"]     ||= "127.0.0.1"
ENV["KIOSK_PROVE_GETGROCERY_CALLBACK_HOST"] ||= "127.0.0.1"
ENV["PROVE_KEY_PEM"]                        ||= File.read(File.expand_path("../dev_prove_key.pem", __dir__))

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
