# frozen_string_literal: true

require "digest"

# A human diner (email + password) or a headless assistant account (no
# credentials). Both are principals; `kiosk.current_user_id()` is this `id`.
class User < ApplicationRecord
  devise :database_authenticatable

  has_many :bookings, dependent: :destroy

  # The name the public reservations board prints: the diner's own, else a
  # pseudonym derived from the account uuid, never from the email address.
  def public_name
    chosen = display_name.to_s.strip
    return chosen unless chosen.empty?

    "diner-#{Digest::SHA256.hexdigest(id.to_s)[0, 12]}"
  end
end
