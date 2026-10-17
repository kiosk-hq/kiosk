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
  c.skill_url         = 'https://kiosk.tech/skill-v0.5.14.md'
  c.skill_sha256      = '9ebc6fd283c0d0abef5610935029a06c8ac862d73f669aed6f593ac86ddab5c2'

  # Demo only: checks every answer in production too. The generated default checks outside production only.
  c.validate_responses = true

  c.user_idp     = Kiosk::UserIdentityProviders::Devise.new
  c.sign_in_path = '/users/sign_in'
end

# Linking an assistant's bare account to a human moves its lists and memberships to the human.
Kiosk.configure do |c|
  c.assistant_claimed = lambda { |from:, to:, **|
    from.lists.update_all(account_id: to.id)
    from.memberships.where.not(list: to.joined_lists).update_all(account_id: to.id)
    from.memberships.delete_all
  }

  c.pow_secret             = ENV.fetch('KIOSK_POW_SECRET')
  c.registration_pow_count = 1
  c.reputation_policy      = Kiosk::Reputation::Policies::RecentSpend.new(trusted_at: 100_00, within: 1.week)
end
