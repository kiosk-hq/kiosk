require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }
  config.assume_ssl = true
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.silence_healthcheck_path = "/up"
  config.active_support.report_deprecations = false
  config.i18n.fallbacks = true
  config.active_record.dump_schema_after_migration = false

  # ── Prove env inputs (K-672) ────────────────────────────────────────────
  # ENV is read HERE, per environment, and published as Rails custom config
  # (Rails.configuration.x.prove.*); lib code and controllers read the
  # config, never ENV — the operator demos' K-650 shape, applied to the
  # broker (prove is the declared exception to their env-file lockstep,
  # K-643, so this block carries broker config, not operator config).

  # Operator intake allow-list — fail-closed (K-547): a shipped default
  # would be world-readable in this public repo, so anyone could present it
  # to drive operator intake and trigger broker→operator callbacks. An
  # operator whose secret is unset is simply NOT registered; `authenticate`
  # rejects it rather than honouring a guessable token.
  config.x.prove.skooti_secret     = ENV["KIOSK_PROVE_SKOOTI_SECRET"]
  config.x.prove.getgrocery_secret = ENV["KIOSK_PROVE_GETGROCERY_SECRET"]

  # The ONLY host the broker will POST each operator's callback to (the
  # SSRF / open-relay guard, design §4.7). No loopback default here: unset
  # means NO callback destination is allow-listed for that operator, so its
  # intakes are refused (403) instead of the broker POSTing to its own
  # loopback services. The deploy sets the operator's real host (CHECKLIST
  # §4b: KIOSK_PROVE_SKOOTI_CALLBACK_HOST=skooti.demo.kiosk.tech).
  config.x.prove.skooti_callback_host     = ENV["KIOSK_PROVE_SKOOTI_CALLBACK_HOST"]
  config.x.prove.getgrocery_callback_host = ENV["KIOSK_PROVE_GETGROCERY_CALLBACK_HOST"]

  # The operator-binding `aud` minted into each operator's attestations —
  # defaults to the operator_id handle (what the demo operators set as
  # c.kyc_audience); overridable for a distinct origin-URL audience, kept in
  # lockstep with the operator's own kyc_audience (K-550).
  config.x.prove.skooti_audience     = ENV.fetch("KIOSK_PROVE_SKOOTI_AUDIENCE", "skooti")
  config.x.prove.getgrocery_audience = ENV.fetch("KIOSK_PROVE_GETGROCERY_AUDIENCE", "getgrocery")

  # The `iss` stamped into every claim; operators pin the SAME value as
  # c.kyc_issuer. Defaults to the deploy origin on BOTH sides (skooti's
  # ProveTrust.issuer names the same literal).
  config.x.prove.issuer = ENV.fetch("KIOSK_PROVE_ISSUER", "https://kyc.demo.kiosk.tech")

  # The public origin stamped into the verification_url handed back at
  # intake — pinned by the deploy so links are correct behind the
  # TLS-terminating proxy; unset → the intake request's own base_url.
  config.x.prove.public_url = ENV["PROVE_PUBLIC_URL"]
end
