require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Make code changes take effect immediately without server restart.
  config.enable_reloading = true

  # Do not eager load code on boot.
  config.eager_load = false

  # Show full error reports.
  config.consider_all_requests_local = true

  # Enable server timing.
  config.server_timing = true

  # Enable/disable Action Controller caching. By default Action Controller caching is disabled.
  # Run rails dev:cache to toggle Action Controller caching.
  if Rails.root.join("tmp/caching-dev.txt").exist?
    config.public_file_server.headers = { "cache-control" => "public, max-age=#{2.days.to_i}" }
  else
    config.action_controller.perform_caching = false
  end

  # Change to :null_store to avoid any caching.
  config.cache_store = :memory_store

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load

  # Highlight code that triggered database queries in logs.
  config.active_record.verbose_query_logs = true

  # Append comments with runtime information tags to SQL queries in logs.
  config.active_record.query_log_tags_enabled = true

  # Highlight code that enqueued background job in logs.
  config.active_job.verbose_enqueue_logs = true

  # Highlight code that triggered redirect in logs.
  config.action_dispatch.verbose_redirect_logs = true

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true

  # Permit the demo's realistic /etc/hosts domain. Rails 8 HostAuthorization
  # otherwise 403s any request whose Host header isn't localhost/127.0.0.1,
  # which blocks `rake demo` when it runs on http://atablefor.demo.kiosk.tech:3002.
  config.hosts << "atablefor.demo.kiosk.tech"

  # ── Kiosk env inputs (K-650) ────────────────────────────────────────────
  # ENV is read HERE, per environment, and published as Rails custom config
  # (Rails.configuration.x.kiosk.*); initializers and lib code read the
  # config, never ENV. Development keeps the out-of-the-box fallbacks
  # production refuses to invent; the block is kept textually identical
  # across the demos even though this file is not lockstep-guarded.

  # Ephemeral dev signing key: the JWT/register flows need one, so when none
  # is provided self-provision an EPHEMERAL RSA key and `demo:setup`/the flow
  # drivers run out of the box. Production never does this — kiosk-server
  # raises its clear KIOSK_SIGNING_KEY_PEM/_B64 message at first use.
  if ENV["KIOSK_SIGNING_KEY_B64"].nil? && ENV["KIOSK_SIGNING_KEY_PEM"].nil?
    require "openssl"
    require "base64"
    ENV["KIOSK_SIGNING_KEY_B64"] = Base64.strict_encode64(OpenSSL::PKey::RSA.new(2048).to_pem)
    warn "[kiosk] WARNING: generated an EPHEMERAL signing key (#{Rails.env}); set KIOSK_SIGNING_KEY_B64/PEM for a stable key."
  end

  # Stable (non-secret) PoW HMAC default so `bin/rails s` and the demo
  # drivers boot with no env; production REQUIRES the variable (K-541). A
  # too-short override is rejected here exactly as in production.
  config.x.kiosk.pow_secret = ENV.fetch("KIOSK_POW_SECRET", "kiosk-demo-pow-secret-dev-insecure-default")
  raise "KIOSK_POW_SECRET must be at least 32 bytes (got #{config.x.kiosk.pow_secret.bytesize}) — generate one with `openssl rand -hex 32`." if config.x.kiosk.pow_secret.bytesize < 32

  # Issuer origin: defaults to the local server origin. PORT defaults to 3000
  # to match config/puma.rb; the demo rake tasks always pass KIOSK_ISSUER
  # explicitly, so the default only serves a bare `rails s`. Production
  # REQUIRES the variable (K-510).
  config.x.kiosk.issuer = ENV.fetch("KIOSK_ISSUER") { "http://localhost:#{ENV.fetch("PORT", "3000")}" }

  # KIOSK_TEST_AUTOCARD=1 (set by the pay demos' rake suites) makes the
  # Stripe adapter simulate a completed SetupIntent — no hosted card-entry
  # step, no server-side test route. Honoured in dev/test only; production
  # pins it OFF.
  config.x.kiosk.test_autocard = ENV["KIOSK_TEST_AUTOCARD"] == "1"

  # KYC broker trust — read by the broker-integrated demos (getgrocery,
  # skooti); inert in the others. No pinned dev broker key and no default
  # intake secret (K-650): the two-server harnesses and the KYC rake tasks
  # pin both sides explicitly (ProveBrokerBoot wiring / the ProveKey public
  # half), so nothing here needs to line up "out of the box".
  config.x.kiosk.prove_public_key_pem = ENV["KIOSK_PROVE_PUBLIC_KEY_PEM"]
  config.x.kiosk.prove_intake_secret =
    ENV["KIOSK_PROVE_GETGROCERY_SECRET"] || ENV["KIOSK_PROVE_SKOOTI_SECRET"]

  # The Ed25519 unlock/rental-token signing key: the FIXED dev keypair the demo
  # ships at config/dev_unlock_key.pem, where it ships one. Fixed rather than
  # ephemeral because the known-answer vector, the firmware fixtures and the
  # lock the flow drivers provision are all pinned to it. Its private half is
  # world-readable in this public repo, which is why production refuses to boot
  # without an explicit KIOSK_UNLOCK_SIGNING_KEY_PEM (K-686).
  dev_unlock_key_file = Rails.root.join("config/dev_unlock_key.pem")
  config.x.kiosk.unlock_signing_key_pem =
    ENV.fetch("KIOSK_UNLOCK_SIGNING_KEY_PEM") { dev_unlock_key_file.read if dev_unlock_key_file.exist? }
end
