require "active_support/core_ext/integer/time"
require "openssl"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Caddy terminates TLS and sends HSTS (deploy/Caddyfile); the session cookie travels over HTTPS only.
  config.session_store :cookie_store, key: "_#{railtie_name.delete_suffix("_application")}_session", secure: true

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  # config.cache_store = :mem_cache_store

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }

  # ── Kiosk env inputs ────────────────────────────────────────────────────
  # ENV is read HERE, per environment, and published as Rails custom config
  # (Rails.configuration.x.kiosk.*); initializers and lib code read the
  # config, never ENV, and never raise — each environment's posture lives in
  # that environment's file. A demo publishes only the keys it reads.

  # The HMAC key every Kiosk PoW challenge is signed with — REQUIRED.
  # This repo is public, so a shipped fallback would be world-readable:
  # anyone could mint a self-signed challenge at trivial difficulty and forge
  # a valid proof, silently turning proof-of-work off.
  config.x.kiosk.pow_secret = ENV.fetch("KIOSK_POW_SECRET") do
    raise <<~MSG
      KIOSK_POW_SECRET is required in production.

      It is the HMAC key every Kiosk PoW challenge is signed with. This repo is
      public, so a shipped fallback would be world-readable — anyone could mint a
      self-signed challenge at trivial difficulty and forge a valid proof,
      silently turning proof-of-work off. Generate a long random value:

        KIOSK_POW_SECRET=$(openssl rand -hex 32)
    MSG
  end
  raise "KIOSK_POW_SECRET must be at least 32 bytes (got #{config.x.kiosk.pow_secret.bytesize}) — generate one with `openssl rand -hex 32`." if config.x.kiosk.pow_secret.bytesize < 32

  # This operator's canonical origin — REQUIRED. It is advertised in
  # /.well-known/kiosk.json, minted as the `iss` of every Kiosk JWT, and
  # enforced as the `aud` of every assistant proof-of-possession; a silent
  # localhost fallback would reject EVERY assistant with "proof audience
  # mismatch" — a total, silent auth outage from one unset variable.
  config.x.kiosk.issuer = ENV.fetch("KIOSK_ISSUER") do
    raise <<~MSG
      KIOSK_ISSUER is required in production.

      It is this operator's canonical origin: advertised in
      /.well-known/kiosk.json, minted as the `iss` of every Kiosk JWT, and
      enforced as the `aud` of every assistant proof-of-possession. Falling
      back to localhost here would reject EVERY assistant with "proof
      audience mismatch".

      Set it to the origin agents actually dial:
        KIOSK_ISSUER=https://<this-demo>.demo.kiosk.tech
    MSG
  end

  # ── Postgres role names ─────────────────────────────────────────────────
  # `app_role` is the non-owner role a request-scoped session drops into when
  # `enforce_db_role` is on; the `SET LOCAL ROLE` expires with the transaction, so
  # nothing switches back. `system_role` is deployment vocabulary for the
  # privileged role a DBA grants ownership to — nothing in kiosk-server or
  # kiosk-rls reads it at runtime, so both names resolve to one default. WHICH
  # roles a database actually has is deployment
  # posture rather than a demo mode, so the names are resolved here with every
  # other env input and the initializer reads the config, never ENV
  # (ENV-CONFIG-PLACEMENT). Nothing in this repo SETS either variable: they are
  # the seam an adopter whose database names its roles differently would use,
  # and this file is where they would name them.
  config.x.kiosk.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  config.x.kiosk.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  # ── The toy bad-proof counters' stores ──────────────────────────────────
  # WHERE the PoW bad-proof counters' sqlite files live — the :demo and
  # :reputation modes keep separate stores. `rake check:pow` OWNS the location:
  # it wipes the file and exports KIOSK_BAD_PROOF_DB to BOTH the server it
  # spawns and the driver that reads the counts back, so the two cannot drift
  # onto different files; the defaults are only for a bare `rails s`.
  config.x.kiosk.bad_proof_db            = ENV.fetch("KIOSK_BAD_PROOF_DB") { Rails.root.join("tmp", "bad-proof.sqlite3").to_s }
  config.x.kiosk.reputation_bad_proof_db = ENV.fetch("KIOSK_BAD_PROOF_DB") { Rails.root.join("tmp", "reputation-bad-proof.sqlite3").to_s }
end
