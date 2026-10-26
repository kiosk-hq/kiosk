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
  # The SHA-256 of the skill file that kiosk-server gives. spec/kiosk_skill_pin_spec.rb says when to change it.
  c.skill_sha256      = 'b44c355038498465d62f7350b2d7e96b3c8122350654e552bc48a2dd18431a97'

  # Demo only: checks every answer in production too. The generated default checks outside production only.
  c.validate_responses = true

  c.user_idp     = Kiosk::UserIdentityProviders::Devise.new
  c.sign_in_path = '/users/sign_in'
end

# Payments: the card setup, the capture, and what follows it.
Kiosk.configure do |c|
  c.payment_provider = Kiosk::Server::PaymentClaim.new(
    # STRIPE_MOCK_URL names a local stripe-mock in development and test.
    Kiosk::PaymentProviders::Stripe.new(api_key: ENV.fetch('STRIPE_SECRET_KEY'),
                                        api_base: ENV.fetch('STRIPE_MOCK_URL', nil)),
    currency: 'eur', model: 'Booking', reference: 'booking_id',
    query: 'my_bookings'
  )
  c.checkout_price_checker = PriceChecker
  c.after_payment          = ->(booking_id) { Booking.captured!(booking_id) }
  c.spending_cap           = Kiosk::Server::ColumnSpendingCap.new
end

# The proof-of-work toll.
Kiosk.configure do |c|
  c.pow_secret             = ENV.fetch('KIOSK_POW_SECRET')
  c.registration_pow_count = 1
  c.reputation_policy      = Kiosk::Reputation::Policies::RecentSpend.new(within: 1.week, cap: 100)
end
