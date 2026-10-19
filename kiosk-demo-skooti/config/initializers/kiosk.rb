# frozen_string_literal: true

require 'base64'
require 'openssl'
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
  c.owner             = { name: 'skooti', support: 'demo@kiosk.tech' }
  c.skill_url         = 'https://kiosk.tech/skill-v0.5.18.md'
  c.skill_sha256      = '91b04ce972c85d168e3ace922a28abfcf41c14cf27f707a6d6564cfd97c5ee5b'

  # Demo only: checks every answer in production too. The generated default checks outside production only.
  c.validate_responses = true

  c.user_idp = Kiosk::UserIdentityProviders::Devise.new
  c.sign_in_path = '/users/sign_in'
end

# Payments: the card setup, the capture, and what follows it.
Kiosk.configure do |c|
  c.payment_provider = Kiosk::Server::PaymentClaim.new(
    # STRIPE_MOCK_URL names a local stripe-mock in development and test.
    Kiosk::PaymentProviders::Stripe.new(api_key: ENV.fetch('STRIPE_SECRET_KEY'),
                                        api_base: ENV.fetch('STRIPE_MOCK_URL', nil)),
    currency: 'eur', model: 'Reservation', reference: 'reservation_id',
    query: 'my_reservations'
  )
  c.cart_price_checker = PriceChecker
end

# KYC: the broker that checks the customer, and the claims this origin asks for.
Kiosk.configure do |c|
  c.kyc_provider = Kiosk::KycProviders::Prove.new(
    operator_id: 'skooti',
    intake_secret: ENV.fetch('KIOSK_PROVE_INTAKE_SECRET'),
    url: ENV.fetch('KIOSK_PROVE_BROKER_URL')
  )
  # A vehicle needs age_over_18 and the licence attribute of its category (Scooter::LICENCE_CATEGORIES).
  c.kyc_claims     = %w[age_over_18 licence_a1 licence_a]
  c.kyc_issuer     = ENV.fetch('KIOSK_PROVE_ISSUER')
  c.kyc_public_key = ENV.fetch('KIOSK_PROVE_PUBLIC_KEY_PEM')
  c.kyc_audience   = 'skooti'

  c.pow_secret             = ENV.fetch('KIOSK_POW_SECRET')
  c.registration_pow_count = 1
  c.reputation_policy      = Kiosk::Reputation::Policies::RecentSpend.new(within: 1.week, cap: 100)
end
