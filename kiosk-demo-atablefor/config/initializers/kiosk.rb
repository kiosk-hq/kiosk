# frozen_string_literal: true

require 'base64'
require 'kiosk/user_identity_providers/devise'

Kiosk.configure do |c|
  c.user_model = 'User'

  c.issuer            = ENV.fetch('KIOSK_ISSUER')
  c.signing_key       = Base64.decode64(ENV.fetch('KIOSK_SIGNING_KEY_B64'))
  c.roles             = %i[customer]
  c.registration_role = :customer

  # Demo only: checks every answer in production too. The generated default checks outside production only.
  c.validate_responses = true

  c.user_idp     = Kiosk::UserIdentityProviders::Devise.new
  c.sign_in_path = '/users/sign_in'
end

# What discovery tells an assistant about this origin.
Kiosk.configure do |c|
  c.owner = {
    name: 'atablefor',
    support: 'demo@kiosk.tech'
  }
  c.skill_url    = 'https://kiosk.tech/skill-v0.5.17.md'
  c.skill_sha256 = '034cbebddd58a4ae6efb91691f4874f43437233999257df3f177f3ff1a8bf761'
end

# The proof-of-work toll.
Kiosk.configure do |c|
  c.pow_secret             = ENV.fetch('KIOSK_POW_SECRET')
  c.registration_pow_count = 1
  c.reputation_policy      = Kiosk::Reputation::Policies::RecentSpend.new(within: 1.week, cap: 100)
end
