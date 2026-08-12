Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = ENV["CI"].present?
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }
  config.consider_all_requests_local = true
  config.cache_store = :null_store
  config.action_dispatch.show_exceptions = :rescuable
  config.action_controller.allow_forgery_protection = false
  config.active_support.deprecation = :stderr
  config.action_controller.raise_on_missing_callback_actions = true

  # ── Prove env inputs (K-672) ────────────────────────────────────────────
  # Same shape as development (ENV read HERE, published as
  # Rails.configuration.x.prove.*; lib code reads the config, never ENV)
  # with ONE relaxation: the request specs drive REAL intake auth for both
  # demo operators — they read the registered secret back off
  # OperatorRegistry.registry and present it as the bearer — so test
  # registers skooti and getgrocery with fixed literals. These are test
  # fixtures, not shipped credentials: production registers an operator only
  # from its ENV (fail-closed, K-547), and development ships no default at
  # all (K-672 — the two-server harnesses pin the secret on both sides).
  config.x.prove.skooti_secret     = ENV.fetch("KIOSK_PROVE_SKOOTI_SECRET", "prove-skooti-test-intake-secret")
  config.x.prove.getgrocery_secret = ENV.fetch("KIOSK_PROVE_GETGROCERY_SECRET", "prove-getgrocery-test-intake-secret")

  # Callback allow-list hosts (SSRF guard §4.7): the specs' callback_urls
  # point at loopback, matching this default.
  config.x.prove.skooti_callback_host     = ENV.fetch("KIOSK_PROVE_SKOOTI_CALLBACK_HOST", "127.0.0.1")
  config.x.prove.getgrocery_callback_host = ENV.fetch("KIOSK_PROVE_GETGROCERY_CALLBACK_HOST", "127.0.0.1")

  # Operator-binding `aud` defaults (the operator_id handle, K-550) and the
  # claim `iss` — the specs assert against these registration-derived values.
  config.x.prove.skooti_audience     = ENV.fetch("KIOSK_PROVE_SKOOTI_AUDIENCE", "skooti")
  config.x.prove.getgrocery_audience = ENV.fetch("KIOSK_PROVE_GETGROCERY_AUDIENCE", "getgrocery")
  config.x.prove.issuer = ENV.fetch("KIOSK_PROVE_ISSUER", "https://kyc.demo.kiosk.tech")
  config.x.prove.public_url = ENV["PROVE_PUBLIC_URL"]
end
