# frozen_string_literal: true

# A Dublin grocery catalog, every shelf at Product::DAILY_STOCK, and one
# shopper who signs in with a password and has a card on file. Assistants
# register themselves on the wire. The wine is age-restricted: a cart holding
# it needs an age_over_18 attestation.
[
  { sku: 'milk-0.5l',        name: 'Milk 0.5 L',                 price_cents: 89 },
  { sku: 'free-range-eggs',  name: 'Free-Range Eggs',            price_cents:  599 },
  { sku: 'sourdough-bread',  name: 'Sourdough Bread',            price_cents:  449 },
  { sku: 'white-bread',      name: 'White Bread',                price_cents:  299 },
  { sku: 'butter-250g',      name: 'Butter 250g',                price_cents:  349 },
  { sku: 'peanut-butter',    name: 'Peanut Butter',              price_cents:  429 },
  { sku: 'greek-yogurt',     name: 'Greek Yogurt',               price_cents:  389 },
  { sku: 'cheddar',          name: 'Cheddar',                    price_cents:  699 },
  { sku: 'apple-juice',      name: 'Apple Juice',                price_cents:  349 },
  { sku: 'spaghetti',        name: 'Spaghetti',                  price_cents:  249 },
  { sku: 'tomato-sauce',     name: 'Tomato Sauce',               price_cents:  329 },
  { sku: 'olive-oil',        name: 'Olive Oil',                  price_cents: 1299 },
  { sku: 'sparkling-water',  name: 'Sparkling Water',            price_cents:  149 },
  { sku: 'still-water',      name: 'Still Water',                price_cents:  129 },
  { sku: 'banana',           name: 'Banana',                     price_cents:  149 },
  { sku: 'table-red-wine',   name: 'House Table Red Wine 750ml', price_cents:  899, age_restricted: true },
  { sku: 'milk-1l',          name: 'Milk 1 L',                   price_cents:  149 },
  { sku: 'chocolate-spread', name: 'Chocolate Spread 400g',      price_cents:  349 }
].each do |product|
  Product.create_with(product.except(:sku).merge(stock: Product::DAILY_STOCK)).find_or_create_by!(sku: product[:sku])
end

password = 'getgrocery-demo-password'
shopper  = User.find_or_initialize_by(id: '00000000-0000-0000-0000-000000000042').tap do |hana|
  hana.email    = 'hana@example.com'
  hana.password = password unless hana.valid_password?(password)
  hana.save!
end

Rails.logger.info "Seeded: #{Product.count} products and #{shopper.email}"
