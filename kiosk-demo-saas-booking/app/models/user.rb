# frozen_string_literal: true

class User < ApplicationRecord
  # Human account holders sign in with email + password (the session that
  # approves assistant links on the verify page). Assistant accounts are
  # rows in this same table WITHOUT credentials — kiosk-pop key possession
  # is their only channel, so they can never drive the human surfaces.
  devise :database_authenticatable

  has_many :appointments, dependent: :destroy
end
