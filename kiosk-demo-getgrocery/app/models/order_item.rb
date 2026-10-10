# frozen_string_literal: true

class OrderItem < ApplicationRecord
  MAX_QTY = 99

  belongs_to :order
  belongs_to :product, optional: true

  # The catalogue handle the caller named; `product` is what it resolved to.
  attribute :sku, :string

  validates :product, presence: { message: ->(item, _) { "#{item.sku.inspect} is not in the catalogue" } }
  validates :qty, numericality: { only_integer: true, in: 1..MAX_QTY }
end
