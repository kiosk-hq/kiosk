# frozen_string_literal: true

require 'base64'
require 'kiosk/user_identity_providers/devise'

Kiosk.configure do |c|
  c.user_model = 'User'

  c.issuer            = ENV.fetch('KIOSK_ISSUER')
  c.signing_key       = Base64.decode64(ENV.fetch('KIOSK_SIGNING_KEY_B64'))
  c.roles             = %i[customer owner]
  c.registration_role = :customer
  c.owner             = { name: 'Stylish (Kiosk demo)', support: 'demo@kiosk.tech' }
  c.skill_url         = 'https://kiosk.tech/skill-v0.6.0.md'
  c.skill_sha256      = '42549a79d69115f2802b32e9db0ec9f4f13c5f836f0ab01af126c9bfa834ec2f'

  # Demo only: checks every answer in production too. The generated default checks outside production only.
  c.validate_responses = true

  # Staff get the owner role from User#kiosk_role at link time.
  c.user_idp     = Kiosk::UserIdentityProviders::Devise.new
  c.sign_in_path = '/users/sign_in'

  c.pow_secret             = ENV.fetch('KIOSK_POW_SECRET')
  c.registration_pow_count = 1
  c.reputation_policy      = Kiosk::Reputation::Policies::RecentSpend.new(within: 1.week, cap: 100)
end
