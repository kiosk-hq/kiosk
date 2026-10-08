# frozen_string_literal: true

require "base64"
require "stripe"
require "kiosk/payment_providers/stripe"
require "kiosk/user_identity_providers/devise"
require "kiosk/pow/equihash"
require "kiosk/reputation"

Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

EQUIHASH_PARAMS = { n: 96, k: 5 }.freeze

# Availability queries per agent, in process.
HOTELING_BROWSE_COUNT = Hash.new(0)

Stripe.api_base = ENV["STRIPE_MOCK_URL"] if ENV["STRIPE_MOCK_URL"]

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id
  c.guc_namespace  = "app"
  c.schema         = "kiosk"
  c.app_role       = "app_role"
  c.system_role    = "app_role"

  c.issuer            = ENV.fetch("KIOSK_ISSUER")
  c.signing_key       = Base64.decode64(ENV.fetch("KIOSK_SIGNING_KEY_B64"))
  c.roles             = %i[customer]
  c.registration_role = :customer
  c.owner             = { name: "hoteling", support: "demo@kiosk.tech" }
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
    currency: "eur", table: "bookings", reference: "booking_id",
    query: "my_bookings", payer_column: "paid_by_user_id",
  )
  c.cart_price_checker = PriceChecker
  c.after_payment      = ->(booking_id) { Booking.paid!(booking_id) }
  c.spending_cap       = Kiosk::Server::ColumnSpendingCap.new

  c.pow_secret         = ENV.fetch("KIOSK_POW_SECRET")
  c.pow_ttl            = 300
  c.reputation_policy  = HotelingBrowsePolicy.new(EQUIHASH_PARAMS)
  c.reputation_factors = ->(identity:, verb:) {
    HOTELING_BROWSE_COUNT[identity.agent_id] += 1 if verb == :query
    Kiosk::Reputation::Factors.new(
      kyc_level: nil, settled_purchases_count: nil, settled_purchases_cents: nil,
      request_rate_per_min: HOTELING_BROWSE_COUNT[identity.agent_id],
      account_age_seconds: nil, dispute_count: nil, bad_proof_count: 0,
    )
  }
  c.registration_pow_count  = 1
  c.registration_pow_params = EQUIHASH_PARAMS

  c.event_store = Kiosk::Server::EventStores::ActiveRecord.new
end

# The closed vocabularies behind the search_hotels enums and the seeds. A
# constant, not a query over properties: an unserved district is a 400, not [].
AMENITY_POOL = %w[wifi breakfast pool spa gym parking rooftop_bar
                  airport_shuttle sea_view pet_friendly restaurant hammam].freeze
NEIGHBOURHOOD_POOL = %w[Sultanahmet Beyoğlu Kadıköy Beşiktaş Şişli Fatih
                        Üsküdar Galata Taksim Ortaköy Bakırköy Nişantaşı].freeze
