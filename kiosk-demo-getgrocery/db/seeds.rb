# frozen_string_literal: true

# One implicit provider catalog — getgroceries serves Neo-Tokyo.
# No Store records: getgroceries IS the store.
#
# In stock: 15 products (Butter 250g is "low": stock=4 ≤ 5)
# Stock 0  : Milk 1 L, Chocolate Spread 400g (absent from catalog → drives
#            AI substitution beats by absence: "chocolate spread" → "peanut butter?";
#            "milk 1 L" → "2 × Milk 0.5 L".)

[
  # ── In-stock products ───────────────────────────────────────────────────────
  { name: "Milk 0.5 L",         price_cents:   89, stock: 80 },
  { name: "Free-Range Eggs",    price_cents:  599, stock: 30 },
  { name: "Sourdough Bread",    price_cents:  449, stock: 20 },
  { name: "White Bread",        price_cents:  299, stock: 40 },
  { name: "Butter 250g",        price_cents:  349, stock:  4 },  # low stock (≤ 5) → "low": true in catalog
  { name: "Peanut Butter",      price_cents:  429, stock: 60 },
  { name: "Greek Yogurt",       price_cents:  389, stock: 15 },
  { name: "Cheddar",            price_cents:  699, stock: 18 },
  { name: "Apple Juice",        price_cents:  349, stock: 25 },
  { name: "Spaghetti",          price_cents:  249, stock: 60 },
  { name: "Tomato Sauce",       price_cents:  329, stock: 45 },
  { name: "Olive Oil",          price_cents: 1299, stock: 12 },
  { name: "Sparkling Water",    price_cents:  149, stock: 70 },
  { name: "Still Water",        price_cents:  129, stock: 80 },
  { name: "Banana",             price_cents:  149, stock: 80 },
  # ── Stock 0: absent from catalog, drive AI substitution beats ───────────────
  { name: "Milk 1 L",           price_cents:  149, stock:  0 },  # AI beat: → 2 × Milk 0.5 L (trivial auto-swap)
  { name: "Chocolate Spread 400g", price_cents: 349, stock: 0 }, # AI beat: → Peanut Butter? (asks user)
].each do |attrs|
  Product.find_or_create_by!(name: attrs[:name]) do |p|
    p.price_cents = attrs[:price_cents]
    p.stock       = attrs[:stock]
  end
end

puts "Seeded: #{Product.count} products (#{Product.where("stock > 0").count} in-stock, #{Product.where(stock: 0).count} out-of-stock)"
puts "  In-stock low (stock ≤ 5): #{Product.where("stock > 0 AND stock <= 5").pluck(:name).join(", ")}"
puts "  Out-of-stock (absent from catalog): #{Product.where(stock: 0).pluck(:name).join(", ")}"
puts "  Delivery city context: Neo-Tokyo"
