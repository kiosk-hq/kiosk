require "active_support/core_ext/integer/time"

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

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  # config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

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

  # Replace the default in-process and non-durable queuing backend for Active Job.
  # config.active_job.queue_adapter = :resque

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

  # ── Kiosk env inputs (K-650) ────────────────────────────────────────────
  # ENV is read HERE, per environment, and published as Rails custom config
  # (Rails.configuration.x.kiosk.*); initializers and lib code read the
  # config, never ENV, and never raise — each environment's posture lives in
  # that environment's file. This file is byte-identical across the seven
  # operator demos (bin/check-demo-copies), so nothing in this block may name
  # a single demo.

  # The HMAC key every Kiosk PoW challenge is signed with — REQUIRED (K-541).
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

  # This operator's canonical origin — REQUIRED (K-510). It is advertised in
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

  # NEVER in production (K-650): the Stripe autocard test shim (a completed
  # SetupIntent simulated without a hosted card-entry step) is pinned OFF
  # here — the live demo runs the real hosted flow. Dev/test honour the flag.
  config.x.kiosk.test_autocard = false

  # KYC broker trust — read by the broker-integrated demos (getgrocery,
  # skooti); inert in the others. NO pinned fallback key in production: the
  # operator trusts ONLY an explicitly supplied broker public key, and with
  # none set the engine's KycVerifier fails closed at the wire. The intake
  # secret has no shipped default either (K-547) — each deploy sets its own
  # operator's variable and leaves the other unset.
  config.x.kiosk.prove_public_key_pem = ENV["KIOSK_PROVE_PUBLIC_KEY_PEM"]
  config.x.kiosk.prove_intake_secret =
    ENV["KIOSK_PROVE_GETGROCERY_SECRET"] || ENV["KIOSK_PROVE_SKOOTI_SECRET"]
end
