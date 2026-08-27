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

  # Permit the demo's realistic /etc/hosts domain (kyc.demo.kiosk.tech is the
  # served broker origin; in local runs the broker answers on 127.0.0.1).
  # Rails 8 HostAuthorization otherwise 403s any Host that isn't
  # localhost/127.0.0.1.
  config.hosts << "kyc.demo.kiosk.tech"

  # ── Prove env inputs (K-672) ────────────────────────────────────────────
  # ENV is read HERE, per environment, and published as Rails custom config
  # (Rails.configuration.x.prove.*); lib code and controllers read the
  # config, never ENV — the same shape as the operator demos' K-650 blocks.
  # prove is the API-only broker and the declared exception to their env-file
  # lockstep (K-643), so this block carries broker config, not operator config.

  # Operator intake allow-list — ENV-only, the SAME fail-closed posture as
  # production (K-547): an operator whose secret is unset is simply NOT
  # registered. The old shipped dev defaults are gone (K-672): since K-650
  # the operator side reads its own KIOSK_PROVE_*_SECRET with NO fallback,
  # so a default here paired with nothing — the two-server harnesses
  # (ProveBrokerBoot) pin the secret explicitly on both sides, and a bare
  # `rails s` broker still serves its human /verify page and /prove_key.pem
  # with no operator registered (intake then answers 401, as it should).
  config.x.prove.skooti_secret     = ENV["KIOSK_PROVE_SKOOTI_SECRET"]
  config.x.prove.getgrocery_secret = ENV["KIOSK_PROVE_GETGROCERY_SECRET"]

  # The ONLY host the broker will POST each operator's callback to (the
  # SSRF / open-relay guard). Non-secret: the harnesses pin the
  # operator's real host; loopback serves any hand-driven local intake.
  config.x.prove.skooti_callback_host     = ENV.fetch("KIOSK_PROVE_SKOOTI_CALLBACK_HOST", "127.0.0.1")
  config.x.prove.getgrocery_callback_host = ENV.fetch("KIOSK_PROVE_GETGROCERY_CALLBACK_HOST", "127.0.0.1")

  # The operator-binding `aud` minted into each operator's attestations —
  # defaults to the operator_id handle (what the demo operators set as
  # c.kyc_audience); overridable for a distinct origin-URL audience, kept in
  # lockstep with the operator's own kyc_audience (K-550).
  config.x.prove.skooti_audience     = ENV.fetch("KIOSK_PROVE_SKOOTI_AUDIENCE", "skooti")
  config.x.prove.getgrocery_audience = ENV.fetch("KIOSK_PROVE_GETGROCERY_AUDIENCE", "getgrocery")

  # The `iss` stamped into every claim; operators pin the SAME value as
  # c.kyc_issuer (their ProveTrust.issuer defaults to the same deploy
  # origin), and the two-server harnesses pin it explicitly on both sides.
  config.x.prove.issuer = ENV.fetch("KIOSK_PROVE_ISSUER", "https://kyc.demo.kiosk.tech")

  # The public origin stamped into the verification_url handed back at
  # intake (the link the human opens). Unset → the controller falls back to
  # the intake request's own base_url, which is right for local runs.
  config.x.prove.public_url = ENV["PROVE_PUBLIC_URL"]

  # The broker's RSA signing key (the "ProveKey" — operators trust its
  # public half). Development uses the FIXED baked keypair in
  # config/dev_prove_key.pem: fixed (not per-boot ephemeral) so a broker
  # restart keeps the key a hand-wired local operator has pinned; the
  # two-server harnesses fetch the public half from the running broker
  # (GET /prove_key.pem, K-650) and so work with ANY key here. Its private
  # half ships in this public repo, which is why production refuses to boot
  # without an explicit PROVE_KEY_PEM (K-673).
  config.x.prove.key_pem = ENV.fetch("PROVE_KEY_PEM") { File.read(Rails.root.join("config/dev_prove_key.pem")) }
end
