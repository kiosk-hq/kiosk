# frozen_string_literal: true

# Synthetic restaurant "Mamma Pizza" with a few menu items.
# No human users needed — agents self-register via /kiosk/auth/register (proof-of-possession handshake).

pizza = Restaurant.find_or_create_by!(name: "Mamma Pizza")

MenuItem.find_or_create_by!(restaurant: pizza, sku: "margherita") do |item|
  item.name        = "Margherita"
  item.price_cents = 1599
end

MenuItem.find_or_create_by!(restaurant: pizza, sku: "pepperoni") do |item|
  item.name        = "Pepperoni"
  item.price_cents = 1899
end

MenuItem.find_or_create_by!(restaurant: pizza, sku: "quattro-formaggi") do |item|
  item.name        = "Quattro Formaggi"
  item.price_cents = 1999
end

puts "Seeded: 1 restaurant (#{pizza.name}), #{MenuItem.count} menu items"
