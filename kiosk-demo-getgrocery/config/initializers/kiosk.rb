# frozen_string_literal: true

require 'base64'
require 'stripe'
require 'kiosk/payment_providers/stripe'
require 'kiosk/kyc_providers/prove'
require 'kiosk/user_identity_providers/devise'

Kiosk.configure do |c|
  c.user_model = 'User'

  c.issuer            = ENV.fetch('KIOSK_ISSUER')
  c.signing_key       = Base64.decode64(ENV.fetch('KIOSK_SIGNING_KEY_B64'))
  c.roles             = %i[customer]
  c.registration_role = :customer
  c.owner             = { name: 'GetGrocery', support: 'demo@kiosk.tech' }
  # The SHA-256 of the skill file that kiosk-server gives. test/kiosk_skill_pin_test.rb says when to change it.
  c.skill_sha256      = '254d99fc5411cbc7ec3a34a35643ca4ffd2d770a6245b6ec58f3e114482409f2'

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
    currency: 'eur', model: 'Order', reference: 'order_id', query: 'my_orders'
  )
  c.checkout_price_checker = PriceChecker
  c.after_payment          = ->(order_id) { FulfilOrderOperation.call(order_id) }
end

# KYC: the broker that checks the customer, and the claims this origin asks for.
Kiosk.configure do |c|
  c.kyc_claims     = %w[age_over_18]
  c.kyc_provider   = Kiosk::KycProviders::Prove.new(
    operator_id: 'getgrocery', intake_secret: ENV.fetch('KIOSK_PROVE_INTAKE_SECRET'),
    url: ENV.fetch('KIOSK_PROVE_BROKER_URL'), issuer: ENV.fetch('KIOSK_PROVE_ISSUER'),
    public_key: ENV.fetch('KIOSK_PROVE_PUBLIC_KEY_PEM')
  )
end

# The proof-of-work toll.
Kiosk.configure do |c|
  c.pow_secret             = ENV.fetch('KIOSK_POW_SECRET')
  c.registration_pow_count = 1
  c.reputation_policy      = Kiosk::Reputation::Policies::RecentSpend.new(within: 1.week, cap: 100)
end
