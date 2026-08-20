# frozen_string_literal: true

# The account principal: ONE table for both human accounts and headless
# assistant-created principals. Human account holders sign in with email +
# password — the Devise session the account-binding surfaces authenticate
# through `kiosk-user-idp-devise`. Assistant accounts are rows in this same
# table WITHOUT credentials; kiosk-pop key possession is their only channel.
class User < ApplicationRecord
  devise :database_authenticatable

  has_many :appointments, dependent: :destroy
end
