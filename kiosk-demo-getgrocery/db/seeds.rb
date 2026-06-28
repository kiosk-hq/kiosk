# frozen_string_literal: true

# Synthetic grocery stores with products (some low/zero stock for substitution demos).
# No human users -- agents self-register via /kiosk/agents/register.

freshmart = Store.find_or_create_by!(name: "FreshMart", city: "Istanbul")
greenbox  = Store.find_or_create_by!(name: "GreenBox",  city: "Istanbul")
daymart   = Store.find_or_create_by!(name: "DayMart",   city: "Ankara")

# FreshMart products
fm_products = [
  { sku: "organic-milk-1l",  name: "Organic Milk 1L",      price_cents:  299, stock: 50 },
  { sku: "free-range-eggs",  name: "Free-Range Eggs (12)", price_cents:  599, stock: 30 },
  { sku: "sourdough-bread",  name: "Sourdough Bread",       price_cents:  449, stock: 20 },
  { sku: "white-bread",      name: "White Bread",           price_cents:  299, stock: 40 },
  { sku: "avocado",          name: "Avocado",               price_cents:  199, stock:  0 },  # OUT
  { sku: "banana",           name: "Banana (bunch)",        price_cents:  149, stock: 80 },
  { sku: "orange-juice-1l",  name: "Orange Juice 1L",       price_cents:  399, stock:  3 },  # LOW
  { sku: "apple-juice-1l",   name: "Apple Juice 1L",        price_cents:  349, stock: 25 },
  { sku: "greek-yogurt",     name: "Greek Yogurt 500g",     price_cents:  389, stock: 15 },
  { sku: "plain-yogurt",     name: "Plain Yogurt 500g",     price_cents:  299, stock: 35 },
  { sku: "cheddar-cheese",   name: "Cheddar Cheese 200g",   price_cents:  699, stock:  2 },  # LOW
  { sku: "gouda-cheese",     name: "Gouda Cheese 200g",     price_cents:  649, stock: 18 },
  { sku: "chicken-breast",   name: "Chicken Breast 500g",   price_cents:  999, stock:  0 },  # OUT
  { sku: "turkey-breast",    name: "Turkey Breast 500g",    price_cents: 1099, stock: 10 },
  { sku: "olive-oil-500ml",  name: "Extra Virgin Olive Oil 500ml", price_cents: 1299, stock: 12 },
  { sku: "sunflower-oil-1l", name: "Sunflower Oil 1L",     price_cents:  599, stock: 30 },
  { sku: "pasta-spaghetti",  name: "Spaghetti 500g",        price_cents:  249, stock: 60 },
  { sku: "tomato-sauce",     name: "Tomato Sauce 400g",     price_cents:  329, stock: 45 },
  { sku: "sparkling-water",  name: "Sparkling Water 1.5L",  price_cents:  149, stock: 70 },
  { sku: "still-water",      name: "Still Water 1.5L",      price_cents:  129, stock: 80 },
]

fm_product_records = fm_products.map do |p|
  Product.find_or_create_by!(store: freshmart, sku: p[:sku]) do |prod|
    prod.name        = p[:name]
    prod.price_cents = p[:price_cents]
    prod.stock       = p[:stock]
  end
end

# Substitution policies for FreshMart: out-of-stock -> suggested alternative
fm_by_sku = fm_product_records.index_by(&:sku)

[
  ["avocado",         "banana"],
  ["orange-juice-1l", "apple-juice-1l"],
  ["cheddar-cheese",  "gouda-cheese"],
  ["chicken-breast",  "turkey-breast"],
].each do |out_sku, suggested_sku|
  out_p  = fm_by_sku[out_sku]
  sug_p  = fm_by_sku[suggested_sku]
  SubstitutionPolicy.find_or_create_by!(store: freshmart, out_product_id: out_p.id) do |sp|
    sp.suggested_product_id = sug_p.id
  end
end

# GreenBox products (fewer, simpler)
gb_products = [
  { sku: "almond-milk-1l",  name: "Almond Milk 1L",   price_cents:  499, stock: 25 },
  { sku: "oat-milk-1l",     name: "Oat Milk 1L",      price_cents:  449, stock: 30 },
  { sku: "blueberries",     name: "Blueberries 250g",  price_cents:  799, stock:  0 },  # OUT
  { sku: "raspberries",     name: "Raspberries 250g",  price_cents:  699, stock: 12 },
  { sku: "granola",         name: "Granola 500g",      price_cents:  599, stock: 20 },
  { sku: "muesli",          name: "Muesli 500g",       price_cents:  549, stock: 15 },
  { sku: "dark-chocolate",  name: "Dark Chocolate 90g", price_cents: 399, stock:  8 },
  { sku: "honey-jar",       name: "Honey Jar 500g",    price_cents:  899, stock:  5 },  # LOW
  { sku: "green-tea",       name: "Green Tea 20 bags",  price_cents: 349, stock: 40 },
  { sku: "herbal-tea",      name: "Herbal Tea 20 bags", price_cents: 299, stock: 50 },
]

gb_product_records = gb_products.map do |p|
  Product.find_or_create_by!(store: greenbox, sku: p[:sku]) do |prod|
    prod.name        = p[:name]
    prod.price_cents = p[:price_cents]
    prod.stock       = p[:stock]
  end
end

gb_by_sku = gb_product_records.index_by(&:sku)

[
  ["blueberries", "raspberries"],
].each do |out_sku, suggested_sku|
  out_p  = gb_by_sku[out_sku]
  sug_p  = gb_by_sku[suggested_sku]
  SubstitutionPolicy.find_or_create_by!(store: greenbox, out_product_id: out_p.id) do |sp|
    sp.suggested_product_id = sug_p.id
  end
end

# DayMart products (Istanbul-style convenience store)
dm_products = [
  { sku: "ayran-500ml",     name: "Ayran 500ml",       price_cents:  199, stock: 60 },
  { sku: "simit",           name: "Simit",              price_cents:   99, stock: 30 },
  { sku: "sucuk",           name: "Sucuk 200g",         price_cents:  799, stock:  0 },  # OUT
  { sku: "pastirma",        name: "Pastirma 200g",      price_cents:  899, stock: 10 },
  { sku: "beyaz-peynir",    name: "Beyaz Peynir 400g",  price_cents:  599, stock: 20 },
  { sku: "kasar",           name: "Kasar Peyniri 400g", price_cents:  699, stock: 15 },
  { sku: "lahmacun",        name: "Lahmacun (4 adet)",  price_cents:  799, stock:  0 },  # OUT
  { sku: "gozleme",         name: "Gozleme",            price_cents:  599, stock: 25 },
]

dm_product_records = dm_products.map do |p|
  Product.find_or_create_by!(store: daymart, sku: p[:sku]) do |prod|
    prod.name        = p[:name]
    prod.price_cents = p[:price_cents]
    prod.stock       = p[:stock]
  end
end

dm_by_sku = dm_product_records.index_by(&:sku)

[
  ["sucuk",    "pastirma"],
  ["lahmacun", "gozleme"],
].each do |out_sku, suggested_sku|
  out_p  = dm_by_sku[out_sku]
  sug_p  = dm_by_sku[suggested_sku]
  SubstitutionPolicy.find_or_create_by!(store: daymart, out_product_id: out_p.id) do |sp|
    sp.suggested_product_id = sug_p.id
  end
end

puts "Seeded: #{Store.count} stores, #{Product.count} products, #{SubstitutionPolicy.count} substitution policies"
puts "  FreshMart: #{fm_product_records.count} products, #{SubstitutionPolicy.where(store: freshmart).count} sub policies"
puts "  GreenBox: #{gb_product_records.count} products, #{SubstitutionPolicy.where(store: greenbox).count} sub policies"
puts "  DayMart: #{dm_product_records.count} products, #{SubstitutionPolicy.where(store: daymart).count} sub policies"
