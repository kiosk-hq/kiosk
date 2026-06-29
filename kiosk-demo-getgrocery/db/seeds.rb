# frozen_string_literal: true

# One implicit provider catalog — getgroceries serves Neo-Tokyo.
# No Store records: getgroceries IS the store.
#
# Products are identified to agents by their stable `sku` (never the numeric DB id).
#
# In stock: 15 products (Butter 250g is "low": stock=4 ≤ 5).
# Stock 0  : Milk 1 L, Chocolate Spread 400g — absent from `catalog` (which hides
#            out-of-stock), so they drive the AI substitution beats by ABSENCE:
#              • "milk 1 L"        → the assistant sees only Milk 0.5 L → orders 2×.
#              • "chocolate spread"→ not in catalog → assistant asks the user
#                                     ("peanut butter instead, or leave for next time?").

[
  # ── In-stock products ───────────────────────────────────────────────────────
  { sku: "milk-0.5l",        name: "Milk 0.5 L",            price_cents:   89, stock: 80 },
  { sku: "free-range-eggs",  name: "Free-Range Eggs",       price_cents:  599, stock: 30 },
  { sku: "sourdough-bread",  name: "Sourdough Bread",       price_cents:  449, stock: 20 },
  { sku: "white-bread",      name: "White Bread",           price_cents:  299, stock: 40 },
  { sku: "butter-250g",      name: "Butter 250g",           price_cents:  349, stock:  4 },  # low (≤5) → "low":true
  { sku: "peanut-butter",    name: "Peanut Butter",         price_cents:  429, stock: 60 },
  { sku: "greek-yogurt",     name: "Greek Yogurt",          price_cents:  389, stock: 15 },
  { sku: "cheddar",          name: "Cheddar",               price_cents:  699, stock: 18 },
  { sku: "apple-juice",      name: "Apple Juice",           price_cents:  349, stock: 25 },
  { sku: "spaghetti",        name: "Spaghetti",             price_cents:  249, stock: 60 },
  { sku: "tomato-sauce",     name: "Tomato Sauce",          price_cents:  329, stock: 45 },
  { sku: "olive-oil",        name: "Olive Oil",             price_cents: 1299, stock: 12 },
  { sku: "sparkling-water",  name: "Sparkling Water",       price_cents:  149, stock: 70 },
  { sku: "still-water",      name: "Still Water",           price_cents:  129, stock: 80 },
  { sku: "banana",           name: "Banana",                price_cents:  149, stock: 80 },
  # ── Stock 0: absent from catalog, drive the AI substitution beats ───────────
  { sku: "milk-1l",          name: "Milk 1 L",              price_cents:  149, stock:  0 },
  { sku: "chocolate-spread", name: "Chocolate Spread 400g", price_cents:  349, stock:  0 },
].each do |attrs|
  Product.find_or_create_by!(sku: attrs[:sku]) do |p|
    p.name        = attrs[:name]
    p.price_cents = attrs[:price_cents]
    p.stock       = attrs[:stock]
  end
end

puts "Seeded: #{Product.count} products (#{Product.where("stock > 0").count} in-stock, #{Product.where(stock: 0).count} out-of-stock)"
puts "  In-stock low (stock ≤ 5): #{Product.where("stock > 0 AND stock <= 5").pluck(:sku).join(", ")}"
puts "  Out-of-stock (absent from catalog): #{Product.where(stock: 0).pluck(:sku).join(", ")}"
puts "  Delivery city context: Neo-Tokyo"
