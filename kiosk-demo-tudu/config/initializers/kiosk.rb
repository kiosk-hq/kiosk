# frozen_string_literal: true

require 'base64'
require 'kiosk/user_identity_providers/devise'

# No payment_provider: tudu takes no money, so discovery advertises no `pay`.
Kiosk.configure do |c|
  c.user_model = 'User'

  c.issuer            = ENV.fetch('KIOSK_ISSUER')
  c.signing_key       = Base64.decode64(ENV.fetch('KIOSK_SIGNING_KEY_B64'))
  c.roles             = %i[customer]
  c.registration_role = :customer
  c.owner             = { name: 'tudu (Kiosk demo)', support: 'demo@kiosk.tech' }
  c.skill_url         = 'https://kiosk.tech/skill-v0.6.13.md'
  c.skill_sha256      = '55569df799ddc44577a57fcd9c2a7df217abea9dfdff9fef5312fe7e4b773027'

  # Demo only: checks every answer in production too. The generated default checks outside production only.
  c.validate_responses = true

  c.user_idp     = Kiosk::UserIdentityProviders::Devise.new
  c.sign_in_path = '/users/sign_in'
end

# Linking an assistant's bare account to a human moves its lists and memberships to the human.
Kiosk.configure do |c|
  c.assistant_claimed = lambda { |from:, to:, **|
    from.lists.find_each { it.update!(account_id: to.id) }
    from.memberships.where.not(list: to.joined_lists).find_each { it.update!(account_id: to.id) }
    from.memberships.delete_all
  }

  c.pow_secret             = ENV.fetch('KIOSK_POW_SECRET')
  c.registration_pow_count = 1
  c.reputation_policy      = Kiosk::Reputation::Policies::RecentSpend.new(within: 1.week, cap: 100)
end
