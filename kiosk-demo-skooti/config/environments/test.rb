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

  # ── Kiosk env inputs (K-650) ────────────────────────────────────────────
  # Same relaxed posture as development (see that file's block): ENV is read
  # HERE and published as Rails.configuration.x.kiosk.*; initializers and lib
  # code read the config, never ENV. No ephemeral signing key is provisioned
  # in test — nothing in the demos' test gates signs a JWT; kiosk-server
  # raises its clear KIOSK_SIGNING_KEY_PEM/_B64 message at first use if a
  # test ever does. This file is byte-identical across the seven operator
  # demos (bin/check-demo-copies).
  config.x.kiosk.pow_secret = ENV.fetch("KIOSK_POW_SECRET", "kiosk-demo-pow-secret-dev-insecure-default")
  raise "KIOSK_POW_SECRET must be at least 32 bytes (got #{config.x.kiosk.pow_secret.bytesize}) — generate one with `openssl rand -hex 32`." if config.x.kiosk.pow_secret.bytesize < 32
  config.x.kiosk.issuer = ENV.fetch("KIOSK_ISSUER") { "http://localhost:#{ENV.fetch("PORT", "3000")}" }
  config.x.kiosk.test_autocard = ENV["KIOSK_TEST_AUTOCARD"] == "1"

# ── Postgres role names (K-699) ─────────────────────────────────────────
# `app_role` is the non-owner role a request-scoped session drops into when
# `enforce_db_role` is on; `system_role` is the owner role the engine returns
# to afterwards. WHICH roles a database actually has is deployment posture
# rather than a demo mode, so the names are resolved here with every other env
# input and the initializer reads the config, never ENV (ENV-CONFIG-PLACEMENT,
# K-650). Nothing in this repo SETS either variable: they are the seam an
# adopter whose database names its roles differently would use, and this file
# is where they would name them.
config.x.kiosk.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
config.x.kiosk.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

# ── The toy bad-proof counter's store (K-1008) ──────────────────────────
# WHERE the demo PoW bad-proof counter's sqlite file lives. A filesystem path
# is per-environment posture rather than a demo mode, so it is resolved here
# with every other env input and the initializer reads the config, never ENV
# (ENV-CONFIG-PLACEMENT, Phil 2026-08-12; K-650, K-699). `rake demo:pow` OWNS
# the location: it wipes the file for a clean slate and exports
# KIOSK_BAD_PROOF_DB to BOTH the server it spawns and the driver that reads
# the counts back, so the two processes cannot drift onto different files and
# report zero at each other; the defaults below are only for a bare `rails s`.
# TWO keys because atablefor's :demo and :reputation PoW branches keep
# SEPARATE stores and this file cannot know which branch will run — an
# explicit KIOSK_BAD_PROOF_DB overrides whichever one is read, which is what
# demo:pow relies on. Published in all seven demos like every other key in
# this block (only atablefor and getgrocery carry a bad-proof counter): these
# blocks are kept identical across the seven, two of them by
# bin/check-demo-copies.
config.x.kiosk.bad_proof_db            = ENV.fetch("KIOSK_BAD_PROOF_DB") { Rails.root.join("tmp", "bad-proof.sqlite3").to_s }
config.x.kiosk.reputation_bad_proof_db = ENV.fetch("KIOSK_BAD_PROOF_DB") { Rails.root.join("tmp", "reputation-bad-proof.sqlite3").to_s }

  # Payment-provider credentials (K-700) — read by whichever demos configure a
  # REAL payment adapter, and never looked at by the others. Same relaxed
  # posture as development: a mock base URL implies a mock key, and with neither
  # variable set a placeholder is enough for everything that does not actually
  # charge, so a suite runs with no payment config at all. Production supplies no
  # placeholder — see production.rb.
  config.x.kiosk.stripe_mock_url   = ENV["STRIPE_MOCK_URL"].presence
  config.x.kiosk.stripe_secret_key = ENV["STRIPE_SECRET_KEY"].presence ||
                                     (config.x.kiosk.stripe_mock_url ? "sk_test_mock" : "sk_test_placeholder")
  config.x.kiosk.prove_public_key_pem = ENV["KIOSK_PROVE_PUBLIC_KEY_PEM"]
  config.x.kiosk.prove_intake_secret  = ENV["KIOSK_PROVE_INTAKE_SECRET"]

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
