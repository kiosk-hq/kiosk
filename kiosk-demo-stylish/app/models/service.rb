# frozen_string_literal: true

class Service < ApplicationRecord
  has_many :appointments, dependent: :restrict_with_exception

  def price_eur = self.class.format_eur(price_cents)

  # "€35", "€49.50".
  def self.format_eur(cents)
    whole, frac = cents.to_i.divmod(100)
    frac.zero? ? "€#{whole}" : format("€%d.%02d", whole, frac)
  end
end
