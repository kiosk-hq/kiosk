# frozen_string_literal: true

# Synthetic restaurant "Mamma Pizza" with a few menu items.
#
# The order_flow.rb / demo:order path self-registers agents via
# /kiosk/auth/register (proof-of-possession handshake), which inserts a fresh
# users row — those principals need no seed. The bin/demo walkthrough instead
# browses and places an order under one STABLE stub principal (StubIdp token,
# no PoP round-trip so the tour stays curl-readable). Because
# `Order belongs_to :user` (load_defaults 8.1 requires the association),
# place_order for that stub principal needs a matching users row; seed it here
# with the same UUID bin/demo's AGENT_TOKEN carries. (saas-booking seeds its
# Alice/Bob stub users for the identical reason.)
WALKTHROUGH_STUB_USER_ID = "00000000-0000-0000-0000-000000000001"
User.find_or_create_by!(id: WALKTHROUGH_STUB_USER_ID)

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

puts "Seeded: 1 walkthrough stub user (#{WALKTHROUGH_STUB_USER_ID}), " \
     "1 restaurant (#{pizza.name}), #{MenuItem.count} menu items"
