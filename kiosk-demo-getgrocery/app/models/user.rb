# frozen_string_literal: true

# The account principal: ONE table for both human shopper accounts and headless
# assistant-created principals — no separate "user" surface.
# `kiosk.current_user_id()` resolves to this table's `id`, so an order placed by
# an assistant bound to a human is tied to that human's account (and reaches
# that human's saved card through `stripe_customers`).
#
# Human shoppers sign in with email + password (the Devise session that approves
# an assistant on the verify page). Assistant accounts are rows in this same
# table WITHOUT credentials — kiosk-pop key possession is their only channel, so
# they can never drive the human surfaces.
class User < ApplicationRecord
  devise :database_authenticatable
end
