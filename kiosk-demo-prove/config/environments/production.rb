# frozen_string_literal: true

require 'active_support/core_ext/integer/time'
require 'openssl'

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  # public/ files carry no digest, so browsers revalidate them against last-modified.
  config.public_file_server.headers = { 'cache-control' => 'no-cache' }
  config.assume_ssl = true
  config.log_tags = [:request_id]
  config.logger   = ActiveSupport::TaggedLogging.logger($stdout)
  config.log_level = ENV.fetch('RAILS_LOG_LEVEL', 'info')
  config.active_support.report_deprecations = false
  config.i18n.fallbacks = true
  config.active_record.dump_schema_after_migration = false

  # The development key ships in this repository, so production refuses it.
  pem = ENV.fetch('PROVE_KEY_PEM')
  prove_key = OpenSSL::PKey.read(pem)
  raise 'PROVE_KEY_PEM must be an Ed25519 private key: openssl genpkey -algorithm ed25519' unless prove_key.oid == 'ED25519' && pem.include?('PRIVATE KEY')

  dev_key = OpenSSL::PKey.read(Rails.root.join('config/dev_prove_key.pem').read)
  raise 'PROVE_KEY_PEM is the development key; generate one: openssl genpkey -algorithm ed25519' if prove_key.public_to_der == dev_key.public_to_der
end
