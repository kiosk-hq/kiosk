# frozen_string_literal: true

require 'base64'
require 'kiosk/user_identity_providers/devise'

# A classifieds board takes no money: no payment_provider, so `pay` is absent from discovery.
Kiosk.configure do |c|
  c.user_model = 'User'

  c.issuer            = ENV.fetch('KIOSK_ISSUER')
  c.signing_key       = Base64.decode64(ENV.fetch('KIOSK_SIGNING_KEY_B64'))
  c.roles             = %i[customer]
  c.registration_role = :customer
  c.owner             = { name: 'philslist (Kiosk demo)', support: 'demo@kiosk.tech' }
  c.skill_url         = 'https://kiosk.tech/skill-v0.6.8.md'
  c.skill_sha256      = '278bfd4bd0d53e3fb45019cf221d71f837cab63270511e976a0cd9ccbbaf2cea'

  # Demo only: checks every answer in production too. The generated default checks outside production only.
  c.validate_responses = true

  c.user_idp     = Kiosk::UserIdentityProviders::Devise.new
  c.sign_in_path = '/users/sign_in'

  c.pow_secret             = ENV.fetch('KIOSK_POW_SECRET')
  c.registration_pow_count = 1
  c.reputation_policy      = Kiosk::Reputation::Policies::RecentSpend.new(within: 1.week, cap: 100)
end
