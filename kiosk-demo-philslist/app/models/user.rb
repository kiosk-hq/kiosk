# frozen_string_literal: true

# The account principal (ADR-0010): ONE table for both human account holders
# and headless assistant-created principals — no separate "user" surface.
# `kiosk.current_user_id()` resolves to this table's `id` (the physical table
# stays `users` so the framework identity wiring matches every other demo; the
# "account" in the design doc is this row).
#
# Human account holders sign in with email + password (the Devise session that
# approves assistant links on the verify page). Assistant accounts are rows in
# this same table WITHOUT credentials — kiosk-pop key possession is their only
# channel, so they can never drive the human surfaces.
class User < ApplicationRecord
  devise :database_authenticatable

  # Listings this account owns (as seller). owner_id is the load-bearing
  # isolation predicate for edit/close (see config/initializers/kiosk.rb).
  has_many :listings, foreign_key: :owner_id, inverse_of: :owner, dependent: :destroy
end
