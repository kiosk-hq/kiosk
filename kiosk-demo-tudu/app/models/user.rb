# frozen_string_literal: true

# The account principal: ONE table for both human account holders and headless
# assistant-created principals — no separate "user" surface (ADR-0010). The
# physical table stays `users` so the framework identity wiring matches every
# other demo; the "account" in the design doc is this row.
# `kiosk.current_user_id()` resolves to this table's `id`.
#
# Human account holders sign in with email + password (the Devise session that
# approves assistant links on the verify page). Assistant accounts are rows in
# this same table WITHOUT credentials — created by the `config.assistant_creation`
# factory when an agent registers headless; kiosk-pop key possession is their
# only channel, so they can never drive the human surfaces. On account-link the
# rebind hook migrates a headless account's lists/memberships to the human.
class User < ApplicationRecord
  devise :database_authenticatable

  # Lists this account OWNS (as the owner principal). account_id is the
  # re-parent target of the assistant_claimed rebind hook.
  has_many :lists, foreign_key: :account_id, inverse_of: :account, dependent: :destroy
  # Every list this account can reach — the membership-based access surface.
  has_many :memberships, foreign_key: :account_id, inverse_of: :account, dependent: :destroy
end
