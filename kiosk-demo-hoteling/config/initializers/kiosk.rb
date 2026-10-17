# frozen_string_literal: true

require 'base64'
require 'stripe'
require 'kiosk/payment_providers/stripe'
require 'kiosk/user_identity_providers/devise'

Kiosk.configure do |c|
  c.user_model = 'User'

  c.issuer            = ENV.fetch('KIOSK_ISSUER')
  c.signing_key       = Base64.decode64(ENV.fetch('KIOSK_SIGNING_KEY_B64'))
  c.roles             = %i[customer]
  c.registration_role = :customer
  c.owner             = { name: 'hoteling', support: 'demo@kiosk.tech' }
  c.skill_url         = 'https://kiosk.tech/skill-v0.5.13.md'
  c.skill_sha256      = '786041de6e738cb55311eb852162509f23115227be9ab1c6837b9741840e990b'

  c.validate_responses = true

  c.user_idp     = Kiosk::UserIdentityProviders::Devise.new
  c.sign_in_path = '/users/sign_in'
end

# Payments: the card setup, the capture, and what follows it.
Kiosk.configure do |c|
  c.payment_provider = Kiosk::Server::PaymentClaim.new(
    Kiosk::PaymentProviders::Stripe.new(api_key: ENV.fetch('STRIPE_SECRET_KEY')),
    currency: 'eur', model: 'Booking', reference: 'booking_id',
    query: 'my_bookings'
  )
  c.cart_price_checker = PriceChecker
  c.after_payment      = ->(booking_id) { Booking.captured!(booking_id) }
  c.spending_cap       = Kiosk::Server::ColumnSpendingCap.new
end

# The proof-of-work toll.
Kiosk.configure do |c|
  c.pow_secret             = ENV.fetch('KIOSK_POW_SECRET')
  c.registration_pow_count = 1
end

# The closed vocabularies behind the search_hotels enums and the seeds. A
# constant, not a query over properties: an unserved district is a 400, not [].
AMENITY_POOL = %w[wifi breakfast pool spa gym parking rooftop_bar
                  airport_shuttle sea_view pet_friendly restaurant hammam].freeze
NEIGHBOURHOOD_POOL = %w[Sultanahmet Beyoğlu Kadıköy Beşiktaş Şişli Fatih
                        Üsküdar Galata Taksim Ortaköy Bakırköy Nişantaşı].freeze
