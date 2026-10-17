# frozen_string_literal: true

json.ignore_nil!
json.array! @products do |product|
  json.extract! product, :sku, :name, :price_cents
  json.price_eur Product.format_eur(product.price_cents)
  json.currency 'eur'
  json.low product.low_stock? || nil
  json.age_restricted product.age_restricted? || nil
end
