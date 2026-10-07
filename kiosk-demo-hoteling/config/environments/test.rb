# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with cache-control for performance.
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  # Show full error reports.
  config.consider_all_requests_local = true
  config.cache_store = :null_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true

  # ── Kiosk env inputs ────────────────────────────────────────────────────
  # Same relaxed posture as development (see that file's block): ENV is read
  # HERE and published as Rails.configuration.x.kiosk.*; initializers and lib
  # code read the config, never ENV. No ephemeral signing key is provisioned
  # in test — nothing in the demos' test gates signs a JWT; kiosk-server
  # raises its clear KIOSK_SIGNING_KEY_PEM/_B64 message at first use if a
  # test ever does. A demo publishes only the keys it reads.
  config.x.kiosk.pow_secret = ENV.fetch("KIOSK_POW_SECRET", "kiosk-demo-pow-secret-dev-insecure-default")
  raise "KIOSK_POW_SECRET must be at least 32 bytes (got #{config.x.kiosk.pow_secret.bytesize}) — generate one with `openssl rand -hex 32`." if config.x.kiosk.pow_secret.bytesize < 32
  config.x.kiosk.issuer = ENV.fetch("KIOSK_ISSUER") { "http://localhost:#{ENV.fetch("PORT", "3000")}" }

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
end
