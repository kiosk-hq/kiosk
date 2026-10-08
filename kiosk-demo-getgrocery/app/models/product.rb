# frozen_string_literal: true

# A catalogue line, referenced on the wire by `sku`.
class Product < ApplicationRecord
  LOW_STOCK_THRESHOLD = 5

  scope :in_stock, -> { where(stock: 1..) }

  # 1299 → "€12.99", 300 → "€3".
  def self.format_eur(cents)
    whole, frac = cents.divmod(100)
    frac.zero? ? "€#{whole}" : format("€%d.%02d", whole, frac)
  end

  def low_stock? = stock <= LOW_STOCK_THRESHOLD
end
