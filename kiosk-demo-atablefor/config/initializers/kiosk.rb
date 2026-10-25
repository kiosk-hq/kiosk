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
  # The SHA-256 of the skill file that kiosk-server gives. test/kiosk_skill_pin_test.rb says when to change it.
  c.skill_sha256 = '108080808f04140f5247eefeb6cd3fea5fd120199343267ef444b80df68066ad'
end

# The proof-of-work toll.
Kiosk.configure do |c|
  c.pow_secret             = ENV.fetch('KIOSK_POW_SECRET')
  c.registration_pow_count = 1
  c.reputation_policy      = Kiosk::Reputation::Policies::RecentSpend.new(within: 1.week, cap: 100)
end
