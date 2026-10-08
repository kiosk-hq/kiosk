# frozen_string_literal: true

require "base64"
require "stripe"
require "kiosk/payment_providers/stripe"
require "kiosk/kyc_providers/prove"
require "kiosk/user_identity_providers/devise"
require "kiosk/pow/equihash"
require "kiosk/reputation"

Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

EQUIHASH_PARAMS = { n: 96, k: 5 }.freeze

Stripe.api_base = ENV["STRIPE_MOCK_URL"] if ENV["STRIPE_MOCK_URL"]

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id
  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  c.issuer            = ENV.fetch("KIOSK_ISSUER")
  c.signing_key       = Base64.decode64(ENV.fetch("KIOSK_SIGNING_KEY_B64"))
  c.roles             = %i[customer]
  c.registration_role = :customer
  c.owner             = { name: "GetGrocery", support: "demo@kiosk.tech" }
  c.skill_url         = "https://kiosk.tech/skill-v0.5.12.md"
  c.skill_sha256      = "cf83b63682cd12ca042a18cae871bef0c2f531b98e068c5b15b38f6973e45756"

  c.validate_requests  = true
  c.validate_responses = true

  c.user_idp     = Kiosk::UserIdentityProviders::Devise.new
  c.sign_in_path = "/users/sign_in"

  c.payment_provider = Kiosk::Server::PaymentClaim.new(
    Kiosk::PaymentProviders::Stripe.new(
      api_key:       ENV.fetch("STRIPE_SECRET_KEY"),
      test_autocard: ENV["KIOSK_TEST_AUTOCARD"] == "1",
    ),
    currency: "eur", table: "orders", reference: "order_id", query: "my_orders",
    status_column: "status", unpaid: "created", owner_column: "user_id",
  )
  c.cart_price_checker = PriceChecker
  c.after_payment      = ->(order_id) { CourierDispatchJob.arm!(order_id) }

  c.kyc_provider   = Kiosk::KycProviders::Prove.new(
    operator_id:   "getgrocery",
    intake_secret: ENV.fetch("KIOSK_PROVE_INTAKE_SECRET"),
    url:           ENV.fetch("KIOSK_PROVE_BROKER_URL"),
  )
  c.kyc_claims     = %w[age_over_18]
  c.kyc_issuer     = ENV.fetch("KIOSK_PROVE_ISSUER")
  c.kyc_public_key = ENV.fetch("KIOSK_PROVE_PUBLIC_KEY_PEM")
  c.kyc_audience   = "getgrocery"

  c.pow_secret              = ENV.fetch("KIOSK_POW_SECRET")
  c.pow_ttl                 = 300
  c.reputation_policy       = CatalogTollPolicy.new(Kiosk::Pow::Equihash.params(**EQUIHASH_PARAMS))
  c.reputation_factors      = ->(**) { Kiosk::Reputation::Factors.empty }
  c.registration_pow_count  = 1
  c.registration_pow_params = EQUIHASH_PARAMS

  c.event_store = Kiosk::Server::EventStores::ActiveRecord.new
end
