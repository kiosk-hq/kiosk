# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.public_file_server.headers = { "cache-control" => "no-cache" }
  config.assume_ssl = true
  config.session_store :cookie_store, key: "_#{railtie_name.delete_suffix("_application")}_session", secure: true
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.silence_healthcheck_path = "/up"
  config.active_support.report_deprecations = false
  config.i18n.fallbacks = true
  config.active_record.dump_schema_after_migration = false
  config.active_record.attributes_for_inspect = [ :id ]

  # config/dev_unlock_key.pem ships in a public repo: anyone could mint a token every lock accepts.
  config.after_initialize do
    dev_key = OpenSSL::PKey.read(Rails.root.join("config/dev_unlock_key.pem").read)
    if Kiosk.configuration.unlock_signing_key.public_to_der == dev_key.public_to_der
      raise "KIOSK_UNLOCK_SIGNING_KEY_PEM is the public dev key; generate one with `openssl genpkey -algorithm ed25519`"
    end
  end
end
