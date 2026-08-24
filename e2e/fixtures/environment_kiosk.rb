
  # ── Kiosk env inputs (K-1009, ENV-CONFIG-PLACEMENT) ─────────────────────────
  # `run.sh` splices this block into the GENERATED app's
  # config/environments/{development,production}.rb, which is where Phil decided
  # env-var reading, dev/test fallbacks and crash-if-absent fetches belong
  # (DECISIONS-LOG 2026-08-12; K-650, K-699). config/initializers/kiosk.rb then
  # READS `Rails.configuration.x.kiosk.*` and resolves nothing itself — the same
  # split all seven demos carry, and since K-1009 bin/check-demo-copies enforces
  # it for this harness fixture too. The variables stay honourable from the
  # OUTSIDE: run.sh exports KIOSK_ISSUER and the audit-sink paths before each
  # boot, and this file is what reads them, once, at boot.
  #
  # ONE block spliced into BOTH files rather than a dev/prod split. The harness
  # only ever boots development (`rails s -e development`), so a production-only
  # posture would be code no gate exercises — but KIOSK_POW_SECRET must still
  # fail LOUD if this app is booted outside development, and a block that lived
  # only in development.rb could not do that. The `unless Rails.env.local?`
  # guard is what lets one block serve both, exactly as the initializer's own
  # fetch did before this moved.

  # PoW HMAC secret — REQUIRED outside development/test (K-541). It is the key
  # the engine signs every PoW challenge with. This repo is PUBLIC, so a shipped
  # fallback would be world-readable: a reader could mint a self-signed challenge
  # at trivial difficulty {n:8,k:1} and forge a proof the server accepts,
  # silently turning proof-of-work OFF. The harness boots development, so it
  # keeps a stable (non-secret) default; a too-short secret is rejected
  # everywhere.
  config.x.kiosk.pow_secret = ENV.fetch("KIOSK_POW_SECRET") do
    unless Rails.env.local?
      raise <<~MSG
        KIOSK_POW_SECRET is required outside development/test.

        It is the HMAC key every Kiosk PoW challenge is signed with. This repo is
        public, so a shipped fallback would be world-readable — anyone could mint a
        self-signed challenge at trivial difficulty and forge a valid proof,
        silently turning proof-of-work off. Generate a long random value:

          KIOSK_POW_SECRET=$(openssl rand -hex 32)
      MSG
    end
    "e2e-demo-pow-secret-dev-insecure-default"
  end
  raise "KIOSK_POW_SECRET must be at least 32 bytes (got #{config.x.kiosk.pow_secret.bytesize}) — generate one with `openssl rand -hex 32`." if config.x.kiosk.pow_secret.bytesize < 32

  # Postgres role names: `app_role` is the non-owner role a request-scoped
  # session drops into when `enforce_db_role` is on, `system_role` the owner role
  # the engine returns to afterwards. run.sh pre-creates both in the harness
  # database. WHICH roles a database actually has is deployment posture rather
  # than a demo mode, so the names are resolved here and the initializer reads
  # the config (K-699).
  config.x.kiosk.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  config.x.kiosk.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  # The issuer/audience every kiosk-pop JWT this origin mints is bound to.
  # run.sh exports the real one (http://127.0.0.1:$SERVER_PORT) before it starts
  # the server; the default is for a hand-started harness app.
  config.x.kiosk.issuer = ENV.fetch("KIOSK_ISSUER", "http://localhost:3001")

  # The operator audit sink's two files (K-828). The PRESENCE of
  # KIOSK_AUDIT_SINK_FILE is what makes the initializer configure a sink at all,
  # and run.sh's second boot UNSETS it to prove the default is nil — so the
  # redacted path is fetched crash-if-absent only when the first one is set,
  # which is exactly the short-circuit the initializer used to carry.
  config.x.kiosk.audit_sink_file = ENV["KIOSK_AUDIT_SINK_FILE"]
  config.x.kiosk.audit_sink_redacted_file =
    config.x.kiosk.audit_sink_file && ENV.fetch("KIOSK_AUDIT_SINK_REDACTED_FILE")
