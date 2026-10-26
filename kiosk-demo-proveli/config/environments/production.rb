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
  pem = ENV.fetch('PROVELI_KEY_PEM')
  proveli_key = OpenSSL::PKey.read(pem)
  raise 'PROVELI_KEY_PEM must be an Ed25519 private key: openssl genpkey -algorithm ed25519' unless proveli_key.oid == 'ED25519' && pem.include?('PRIVATE KEY')

  dev_key = OpenSSL::PKey.read(Rails.root.join('config/dev_proveli_key.pem').read)
  raise 'PROVELI_KEY_PEM is the development key; generate one: openssl genpkey -algorithm ed25519' if proveli_key.public_to_der == dev_key.public_to_der
end
