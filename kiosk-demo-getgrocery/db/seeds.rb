# frozen_string_literal: true

# A Dublin grocery catalog, and one shopper who signs in with a password and
# has a card on file. Assistants register themselves on the wire.
#
# Milk 1 L and the chocolate spread are out of stock, so `catalog` leaves them
# out and an assistant has to offer a substitute. The wine is age-restricted:
# a cart holding it needs an age_over_18 attestation.
[
  { sku: "milk-0.5l",        name: "Milk 0.5 L",                 price_cents:   89, stock: 80 },
  { sku: "free-range-eggs",  name: "Free-Range Eggs",            price_cents:  599, stock: 30 },
  { sku: "sourdough-bread",  name: "Sourdough Bread",            price_cents:  449, stock: 20 },
  { sku: "white-bread",      name: "White Bread",                price_cents:  299, stock: 40 },
  { sku: "butter-250g",      name: "Butter 250g",                price_cents:  349, stock:  4 },
  { sku: "peanut-butter",    name: "Peanut Butter",              price_cents:  429, stock: 60 },
  { sku: "greek-yogurt",     name: "Greek Yogurt",               price_cents:  389, stock: 15 },
  { sku: "cheddar",          name: "Cheddar",                    price_cents:  699, stock: 18 },
  { sku: "apple-juice",      name: "Apple Juice",                price_cents:  349, stock: 25 },
  { sku: "spaghetti",        name: "Spaghetti",                  price_cents:  249, stock: 60 },
  { sku: "tomato-sauce",     name: "Tomato Sauce",               price_cents:  329, stock: 45 },
  { sku: "olive-oil",        name: "Olive Oil",                  price_cents: 1299, stock: 12 },
  { sku: "sparkling-water",  name: "Sparkling Water",            price_cents:  149, stock: 70 },
  { sku: "still-water",      name: "Still Water",                price_cents:  129, stock: 80 },
  { sku: "banana",           name: "Banana",                     price_cents:  149, stock: 80 },
  { sku: "table-red-wine",   name: "House Table Red Wine 750ml", price_cents:  899, stock: 24, age_restricted: true },
  { sku: "milk-1l",          name: "Milk 1 L",                   price_cents:  149, stock:  0 },
  { sku: "chocolate-spread", name: "Chocolate Spread 400g",      price_cents:  349, stock:  0 },
].each do |product|
  Product.create_with(product.except(:sku)).find_or_create_by!(sku: product[:sku])
end

password = "getgrocery-demo-password"
shopper  = User.find_or_initialize_by(id: "00000000-0000-0000-0000-000000000042").tap do |hana|
  hana.email    = "hana@example.com"
  hana.password = password unless hana.valid_password?(password)
  hana.save!
end

# The saved card is a stripe-mock fixture, so it is mapped only against the mock;
# against real Stripe the shopper saves one on the hosted setup page.
if ENV["STRIPE_MOCK_URL"]
  Kiosk::PaymentProviders::Stripe::CustomerRecord.create_with(customer_id: "cus_getgrocery_saved_card")
                                                 .find_or_create_by!(user_id: shopper.id)
end

Rails.logger.info "Seeded: #{Product.count} products, #{Product.where(stock: 0).count} out of stock, and #{shopper.email}"
