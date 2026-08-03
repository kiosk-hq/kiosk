# frozen_string_literal: true

# A salon service on the menu (Cut, Colour, …) priced in EUR cents.
class Service < ApplicationRecord
  has_many :appointments, dependent: :restrict_with_exception

  # Price formatted as a EUR string, e.g. "€35" / "€49.50".
  def price_eur = self.class.format_eur(price_cents)

  def self.format_eur(cents)
    cents = cents.to_i
    whole, frac = cents.divmod(100)
    frac.zero? ? "€#{whole}" : format("€%d.%02d", whole, frac)
  end
end
