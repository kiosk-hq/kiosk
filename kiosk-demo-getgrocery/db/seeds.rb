# frozen_string_literal: true

# One implicit provider catalog — getgrocery serves Dublin.
# No Store records: getgrocery IS the store.
#
# Products are identified to agents by their stable `sku` (never the numeric DB id).
#
# In stock: 16 products — 15 groceries (Butter 250g is "low": stock=4 ≤ 5) plus
#           the age-restricted House Table Red Wine 750ml below. The closing
#           `puts` derives these counts; this header is the only place they are
#           written by hand, so keep the two agreeing.
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
  # ── Age-restricted (alcohol): buying it requires an 18+ anonymized-KYC gate ──
  # The LOW-liability age-gated-purchase showcase for anonymized KYC — a coined
  # wine (no real brand). A cart containing it needs an age_over_18 attestation
  # at create_order; every other grocery item stays age_restricted:false.
  { sku: "table-red-wine",   name: "House Table Red Wine 750ml", price_cents: 899, stock: 24, age_restricted: true },
  # ── Stock 0: absent from catalog, drive the AI substitution beats ───────────
  { sku: "milk-1l",          name: "Milk 1 L",              price_cents:  149, stock:  0 },
  { sku: "chocolate-spread", name: "Chocolate Spread 400g", price_cents:  349, stock:  0 },
].each do |attrs|
  Product.find_or_create_by!(sku: attrs[:sku]) do |p|
    p.name           = attrs[:name]
    p.price_cents    = attrs[:price_cents]
    p.stock          = attrs[:stock]
    p.age_restricted = attrs.fetch(:age_restricted, false)
  end
end

# ── Human account holder with a card on file (claim-rebind walkthrough) ─────
# One seeded human: `rake demo:claim` re-binds a standalone assistant's key to
# THIS account, then pays with the account's saved card. The card is
# represented the way the app represents every saved card — a
# `stripe_customers` mapping row (in the live flow the human creates it once
# on the Stripe-hosted SetupIntent page); the walkthrough runs against
# stripe-mock, which serves the card fixture for that customer.
HUMAN_ID     = "00000000-0000-0000-0000-000000000042"
HUMAN_CUS_ID = "cus_getgrocery_saved_card"
# Demo-only credentials (development database, reset by every demo:setup). The
# shopper signs in at /users/sign_in with a real Devise session — the channel
# the account-binding surfaces authenticate, and the one `rake demo:claim`
# drives. There is no stub user-IdP.
HUMAN_EMAIL    = "hana@example.com"
HUMAN_PASSWORD = "getgrocery-demo-password"

User.find_or_create_by!(id: HUMAN_ID) do |u|
  u.email    = HUMAN_EMAIL
  u.password = HUMAN_PASSWORD
end
StripeCustomer.find_or_create_by!(user_id: HUMAN_ID) do |sc|
  sc.customer_id = HUMAN_CUS_ID
end

puts "Seeded: #{Product.count} products (#{Product.where("stock > 0").count} in-stock, #{Product.where(stock: 0).count} out-of-stock)"
# Per-product catalog the operator sees on setup — prices in EUR (€5.99), never
# raw cents. The wire/DB stays canonical integer cents; this is display only.
Product.where("stock > 0").order(:name).each do |p|
  puts "  #{p.name} — #{Product.format_eur(p.price_cents)} (#{p.sku})"
end
puts "  In-stock low (stock ≤ 5): #{Product.where("stock > 0 AND stock <= 5").pluck(:sku).join(", ")}"
puts "  Age-restricted (18+ anonymized-KYC gate at purchase): #{Product.where(age_restricted: true).pluck(:sku).join(", ")}"
puts "  Out-of-stock (absent from catalog): #{Product.where(stock: 0).pluck(:sku).join(", ")}"
puts "  Delivery city context: Dublin"
puts "  Account holder with saved card: #{HUMAN_ID} (#{HUMAN_CUS_ID})"
