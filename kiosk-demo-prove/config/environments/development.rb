require "active_support/core_ext/integer/time"

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

  # Permit the demo's realistic /etc/hosts domain (prove.demo.kiosk.tech is the
  # production brand; in local runs the broker answers on 127.0.0.1). Rails 8
  # HostAuthorization otherwise 403s any Host that isn't localhost/127.0.0.1.
  config.hosts << "prove.demo.kiosk.tech"
  config.hosts << "kyc.demo.kiosk.tech"
end
