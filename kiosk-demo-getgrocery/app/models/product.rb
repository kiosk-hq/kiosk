# frozen_string_literal: true

# A catalogue line, referenced in the protocol by `sku`.
class Product < ApplicationRecord
  LOW_STOCK_THRESHOLD = 5
  MAX_PRICE_CENTS     = 100_000
  # Every shelf holds this many each morning: two of each for 200 shoppers.
  DAILY_STOCK = 400
  SOLD_OUT    = 'Sold out. Check back tomorrow.'

  validates :price_cents, numericality: { only_integer: true, in: 1..MAX_PRICE_CENTS }

  # 1299 → "€12.99", 300 → "€3".
  def self.format_eur(cents)
    whole, frac = cents.divmod(100)
    frac.zero? ? "€#{whole}" : format('€%<whole>d.%<frac>02d', whole:, frac:)
  end

  def low_stock? = stock.between?(1, LOW_STOCK_THRESHOLD)

  def sold_out? = stock.zero?

  # Takes `qty` off the shelf when it holds that many; false when it does not.
  # The row lock makes concurrent payments take turns, so no item goes twice.
  def self.take!(id, qty)
    product = lock.find(id)
    product.stock >= qty && product.update!(stock: product.stock - qty)
  end

  # The morning delivery: every shelf back to DAILY_STOCK (RestockJob).
  def self.restock! = find_each { it.update!(stock: DAILY_STOCK) }
end
