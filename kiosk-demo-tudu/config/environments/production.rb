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

  # Payment-provider credentials (K-700) — REQUIRED by whichever demos configure
  # a REAL payment adapter, and never looked at by the others. Deliberately NO
  # placeholder here, unlike dev and test: a shipped `sk_test_…` placeholder
  # boots an origin that ADVERTISES `pay` in its discovery document and then
  # fails at the first charge, with a human waiting on it. A configured mock
  # base URL is the one exception, and it is not a fallback — pointing a
  # production process at a local stripe-mock is an explicit act, and it is what
  # the eager-load gate does to boot a payment demo without carrying a key.
  # This file is byte-identical across the seven operator demos, so it cannot
  # name the one demo that takes money: it publishes what the environment
  # supplied, and the app that wires a payment provider is the one that refuses
  # to boot with neither, by name, in its own initializer.
  config.x.kiosk.stripe_mock_url   = ENV["STRIPE_MOCK_URL"].presence
  config.x.kiosk.stripe_secret_key = ENV["STRIPE_SECRET_KEY"].presence ||
                                     (config.x.kiosk.stripe_mock_url ? "sk_test_mock" : nil)

  # KYC broker trust — read by whichever demos ship a broker client
  # (app/services/prove_broker_client.rb); inert in the others, which never
  # look at it.
  # NO pinned fallback key in production: the operator trusts ONLY an
  # explicitly supplied broker public key, and with none set the engine's
  # KycVerifier fails closed at the wire.
  #
  # The intake secret is ONE variable named for the ROLE it plays here, not
  # for the operator that plays it (K-694) — the same discipline the unlock
  # key below keeps by keying off a marker file. It has no shipped default
  # (K-547). A per-operator name would have to be picked with an `||` chain
  # in this byte-identical file, and a process that carried two operators'
  # secrets would then present the wrong one to the broker and be rejected
  # (or, worse, accepted) with nothing to say why. Each deploy sets its own
  # KIOSK_PROVE_INTAKE_SECRET to the value the broker holds for THAT
  # operator; the broker keys its registry by the operator_id the intake body
  # carries, so the two sides pair by value, never by variable name.
  config.x.kiosk.prove_public_key_pem = ENV["KIOSK_PROVE_PUBLIC_KEY_PEM"]
  config.x.kiosk.prove_intake_secret  = ENV["KIOSK_PROVE_INTAKE_SECRET"]

  # The Ed25519 key offline unlock/rental tokens are signed with — REQUIRED by
  # the demos that issue them (K-686). This file is byte-identical across the
  # seven operator demos, so what makes the variable required here is not a
  # demo name but the marker every issuing demo carries: a shipped dev keypair
  # at config/dev_unlock_key.pem. A demo with no lock ships no such file,
  # requires no variable, and reads nil.
  #
  # There is deliberately NO fallback to that dev keypair. Its private half is
  # world-readable in this public repo, so signing production tokens with it
  # would let anyone with a clone mint a token every provisioned lock accepts —
  # past reserve, past payment, past the ownership check, past KYC. It is a
  # physical-access credential: the blast radius is a vehicle, not a row. That
  # is exactly what shipped until K-686, under a comment promising an
  # env-loaded PEM that never arrived.
  dev_unlock_key_file = Rails.root.join("config/dev_unlock_key.pem")
  if dev_unlock_key_file.exist?
    config.x.kiosk.unlock_signing_key_pem = ENV.fetch("KIOSK_UNLOCK_SIGNING_KEY_PEM") do
      raise <<~MSG
        KIOSK_UNLOCK_SIGNING_KEY_PEM is required in production.

        It is the Ed25519 key this operator signs offline unlock/rental tokens
        with; every lock verifies against its public half. The dev keypair at
        config/dev_unlock_key.pem ships in this public repo, so falling back to
        it would let anyone with a clone mint a token every provisioned lock
        accepts. Generate a fresh key — and provision the locks with ITS public
        half:

          KIOSK_UNLOCK_SIGNING_KEY_PEM=$(openssl genpkey -algorithm ed25519)
      MSG
    end
    # Fail at boot, not at the first unlock: a value that does not parse — or
    # carries only the public half — would otherwise 500 the first start_rental,
    # which is a request some human is standing next to a scooter waiting on.
    begin
      unlock_key = OpenSSL::PKey.read(config.x.kiosk.unlock_signing_key_pem)
      unless unlock_key.oid == "ED25519"
        raise "KIOSK_UNLOCK_SIGNING_KEY_PEM must be an Ed25519 key (got #{unlock_key.oid}) — the locks verify Ed25519 signatures; generate one with `openssl genpkey -algorithm ed25519`."
      end
      unlock_key.private_to_pem # raises unless the PRIVATE half is there
    rescue OpenSSL::PKey::PKeyError => e
      raise "KIOSK_UNLOCK_SIGNING_KEY_PEM does not parse as an Ed25519 PRIVATE key PEM (#{e.message}) — generate one with `openssl genpkey -algorithm ed25519`."
    end

    # And refuse the SHIPPED DEV KEY ITSELF. The three checks above only prove
    # the supplied value is *an* Ed25519 private key — pasting the world-
    # readable config/dev_unlock_key.pem into the variable satisfies every one
    # of them, and production boots signing tokens anyone with a clone can
    # mint. Requiring the variable (above) closed the SILENT path to that key;
    # this closes the explicit one, which is a plausible reaction to a boot
    # that demands a PEM nobody has generated yet. Same refusal the demo's own
    # test issuer keeps (script/prove_test_issuer.rb, where a dev-key fallback
    # will not arm under a production env), one layer down.
    #
    # Compared on the PUBLIC half in DER, never on PEM text: one key
    # re-serialised (raw vs PKCS#8, CRLF, a stray trailing newline) is a
    # different string and the same credential.
    dev_unlock_key_der =
      begin
        OpenSSL::PKey.read(dev_unlock_key_file.read).public_to_der
      rescue OpenSSL::PKey::PKeyError
        # A marker file that is not a parseable key is not a key anything can
        # sign with either, so there is nothing here for the check to catch.
        nil
      end
    if unlock_key.public_to_der == dev_unlock_key_der
      raise <<~MSG
        KIOSK_UNLOCK_SIGNING_KEY_PEM is the DEV keypair shipped at
        config/dev_unlock_key.pem — refusing to boot production with it.

        Its PRIVATE half is world-readable in this public repo, so every
        unlock/rental token signed with it can be forged by anyone with a
        clone — past reserve, past payment, past the ownership check, past
        KYC. It is a physical-access credential: the blast radius is a
        vehicle, not a row. Supplying that key explicitly re-opens exactly
        what requiring this variable closed.

        Generate a FRESH key — and provision the locks with ITS public half:

          KIOSK_UNLOCK_SIGNING_KEY_PEM=$(openssl genpkey -algorithm ed25519)
      MSG
    end
  end
end
