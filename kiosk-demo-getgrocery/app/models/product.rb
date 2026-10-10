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
    frac.zero? ? "€#{whole}" : format("€%d.%02d", whole, frac)
  end

  def low_stock? = stock <= LOW_STOCK_THRESHOLD
end
