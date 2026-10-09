require "active_support/core_ext/integer/time"

require "openssl"

# The KYC broker as the local operator demos expect it: their issuer, their intake
# secrets, callbacks on loopback, and the development signing key.
ENV["KIOSK_PROVE_ISSUER"]                   ||= "https://kyc.test.local"
ENV["KIOSK_PROVE_SKOOTI_SECRET"]            ||= "prove-skooti-demo-shared-secret"
ENV["KIOSK_PROVE_GETGROCERY_SECRET"]        ||= "prove-getgrocery-demo-shared-secret"
ENV["KIOSK_PROVE_SKOOTI_CALLBACK_HOST"]     ||= "127.0.0.1"
ENV["KIOSK_PROVE_GETGROCERY_CALLBACK_HOST"] ||= "127.0.0.1"
ENV["PROVE_KEY_PEM"]                        ||= File.read(File.expand_path("../dev_prove_key.pem", __dir__))

Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.server_timing = true

  if Rails.root.join("tmp/caching-dev.txt").exist?
    config.public_file_server.headers = { "cache-control" => "public, max-age=#{2.days.to_i}" }
  else
    config.action_controller.perform_caching = false
  end

  config.cache_store = :memory_store
  config.active_support.deprecation = :log
  config.active_record.migration_error = :page_load
  config.active_record.verbose_query_logs = true
  config.action_controller.raise_on_missing_callback_actions = true

  # Permit the demo's realistic /etc/hosts domain (kyc.demo.kiosk.tech is the
  # served broker origin; in local runs the broker answers on 127.0.0.1).
  # Rails 8 HostAuthorization otherwise 403s any Host that isn't
  # localhost/127.0.0.1.
  config.hosts << "kyc.demo.kiosk.tech"
end
