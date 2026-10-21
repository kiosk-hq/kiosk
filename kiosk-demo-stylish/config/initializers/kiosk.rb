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
  c.skill_url         = 'https://kiosk.tech/skill-v0.6.2.md'
  c.skill_sha256      = 'c3b4e958804237e9167f3f331452e9119bf8c8d578ab813b8adfd5beec328608'

  # Demo only: checks every answer in production too. The generated default checks outside production only.
  c.validate_responses = true

  # Staff get the owner role from User#kiosk_role at link time.
  c.user_idp     = Kiosk::UserIdentityProviders::Devise.new
  c.sign_in_path = '/users/sign_in'

  c.pow_secret             = ENV.fetch('KIOSK_POW_SECRET')
  c.registration_pow_count = 1
  c.reputation_policy      = Kiosk::Reputation::Policies::RecentSpend.new(within: 1.week, cap: 100)
end
