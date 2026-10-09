# frozen_string_literal: true

require "base64"
require "kiosk/user_identity_providers/devise"
require "kiosk/pow/equihash"
require "kiosk/reputation"

Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)

EQUIHASH_PARAMS = { n: 96, k: 5 }.freeze

# No payment_provider: tudu takes no money, so discovery advertises no `pay`.
Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id
  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  c.issuer            = ENV.fetch("KIOSK_ISSUER")
  c.signing_key       = Base64.decode64(ENV.fetch("KIOSK_SIGNING_KEY_B64"))
  c.roles             = %i[customer]
  c.registration_role = :customer
  c.owner             = { name: "tudu (Kiosk demo)", support: "demo@kiosk.tech" }
  c.skill_url         = "https://kiosk.tech/skill-v0.5.12.md"
  c.skill_sha256      = "cf83b63682cd12ca042a18cae871bef0c2f531b98e068c5b15b38f6973e45756"

  c.validate_requests  = true
  c.validate_responses = true

  c.user_idp     = Kiosk::UserIdentityProviders::Devise.new
  c.sign_in_path = "/users/sign_in"

  # An assistant registering with no human behind it gets a bare account; linking
  # it later moves that account's lists and memberships to the human.
  c.assistant_creation = ->(_pubkey) { User.create!.id }
  c.assistant_claimed = ->(agent:, from:, to:) do
    from.lists.update_all(account_id: to.id)
    from.memberships.where.not(list: to.joined_lists).update_all(account_id: to.id)
    from.memberships.delete_all
  end

  c.pow_secret              = ENV.fetch("KIOSK_POW_SECRET")
  c.registration_pow_count  = 1
  c.registration_pow_params = EQUIHASH_PARAMS

  c.event_store = Kiosk::Server::EventStores::ActiveRecord.new
end
