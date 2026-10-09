require "active_support/core_ext/integer/time"
require "openssl"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  # public/ files carry no digest, so browsers revalidate them against last-modified.
  config.public_file_server.headers = { "cache-control" => "no-cache" }
  config.assume_ssl = true
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.silence_healthcheck_path = "/up"
  config.active_support.report_deprecations = false
  config.i18n.fallbacks = true
  config.active_record.dump_schema_after_migration = false

  # The development key ships in this repository, so production refuses it.
  prove_key = OpenSSL::PKey::RSA.new(ENV.fetch("PROVE_KEY_PEM"))
  raise "PROVE_KEY_PEM must be an RSA private key: openssl genrsa 2048" unless prove_key.private?
  dev_key = OpenSSL::PKey::RSA.new(Rails.root.join("config/dev_prove_key.pem").read)
  raise "PROVE_KEY_PEM is the development key; generate one: openssl genrsa 2048" if prove_key.public_to_der == dev_key.public_to_der
end
