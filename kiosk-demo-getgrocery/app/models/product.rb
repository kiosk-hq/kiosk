# frozen_string_literal: true

# A catalogue line, referenced on the wire by `sku`.
class Product < ApplicationRecord
  LOW_STOCK_THRESHOLD = 5
  MAX_PRICE_CENTS     = 100_000

  validates :price_cents, numericality: { only_integer: true, in: 1..MAX_PRICE_CENTS }

  scope :in_stock, -> { where(stock: 1..) }

  # 1299 → "€12.99", 300 → "€3".
  def self.format_eur(cents)
    whole, frac = cents.divmod(100)
    frac.zero? ? "€#{whole}" : format('€%<whole>d.%<frac>02d', whole:, frac:)
  end

  def low_stock? = stock <= LOW_STOCK_THRESHOLD

  # One statement, so concurrent payments never lose a decrement. A shelf
  # oversold by a payment race reads 0.
  def self.take!(id, qty) = where(id:).update_all(['stock = GREATEST(stock - ?, 0)', qty])
end
