# frozen_string_literal: true

require "base64"
require "stripe"
require "kiosk/payment_providers/stripe"
require "kiosk/user_identity_providers/devise"
require "kiosk/pow/equihash"
require "kiosk/reputation"

Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

E2E_REGISTRATION_POW_PARAMS = { n: 96, k: 5 }.freeze

Stripe.api_base = ENV.fetch("STRIPE_MOCK_URL")

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id
  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  c.issuer             = ENV.fetch("KIOSK_ISSUER")
  c.additional_origins = ENV.fetch("KIOSK_ADDITIONAL_ORIGINS", "").split(",")
  c.signing_key        = Base64.decode64(ENV.fetch("KIOSK_SIGNING_KEY_B64"))
  c.roles              = %i[customer]
  c.registration_role  = :customer
  c.owner              = { name: "Combette E2E Demo", support: "demo@kiosk.tech" }

  c.registration_pow_count  = 1
  c.registration_pow_params = E2E_REGISTRATION_POW_PARAMS
  c.pow_secret              = ENV.fetch("KIOSK_POW_SECRET")

  c.user_idp = Kiosk::UserIdentityProviders::Devise.new

  c.payment_provider = Kiosk::PaymentProviders::Stripe.new(
    api_key: "sk_test_mock", test_autocard: ENV["KIOSK_TEST_AUTOCARD"] == "1",
  )

  c.event_store        = Kiosk::Server::EventStores::ActiveRecord.new
  c.validate_requests  = true
  c.validate_responses = true

  # run.sh's second boot leaves KIOSK_AUDIT_SINK_FILE unset to prove the default is no sink.
  if (audit_path = ENV["KIOSK_AUDIT_SINK_FILE"])
    c.audit_sink = DemoAuditSink.new(path: audit_path, redacted_path: ENV.fetch("KIOSK_AUDIT_SINK_REDACTED_FILE"))
  end
end
