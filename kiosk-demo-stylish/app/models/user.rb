# frozen_string_literal: true

# Salon staff and customers sign in with a password; an assistant's account is
# a row with no credentials, reachable only through its Kiosk key.
class User < ApplicationRecord
  devise :database_authenticatable

  enum :staff_role, { owner: "owner" }, validate: { allow_nil: true }

  has_many :appointments, dependent: :destroy

  # The Kiosk role the Devise adapter assigns this person's assistant.
  def kiosk_role = staff_role || "customer"
end
