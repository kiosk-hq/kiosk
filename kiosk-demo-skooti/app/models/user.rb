# frozen_string_literal: true

# The account principal: ONE table for both human rider accounts and headless
# assistant-created principals — no separate "user" surface.
# `kiosk.current_user_id()` resolves to this table's `id`, so a rental started
# by an assistant bound to a human is tied to that human's account.
#
# Human riders sign in with email + password (the Devise session that mints the
# link code approving an assistant). Assistant accounts are rows in this same
# table WITHOUT credentials — kiosk-pop key possession is their only channel, so
# they can never drive the human surfaces.
class User < ApplicationRecord
  devise :database_authenticatable

  has_many :reservations, dependent: :destroy
end
