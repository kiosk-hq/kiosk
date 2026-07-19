# frozen_string_literal: true

# Seeds the philslist classifieds board:
#   - two account holders, Alice and Bob, with STABLE UUIDs the assistant
#     scripts use in `Authorization: Bearer agent:u-<uuid>:a-<agent>:r-<role>`
#     headers. Both get Devise credentials so the account-binding walkthrough
#     can sign in through the real /users/sign_in form (Alice approves the
#     assistant link there).
#   - the five categories.
#   - a couple of listings owned across Alice and Bob so browse_listings is
#     genuinely cross-owner and my_listings has a non-vacuous positive control.

ALICE_ID = "00000000-0000-0000-0000-000000000001"
BOB_ID   = "00000000-0000-0000-0000-000000000002"

# Demo-only credentials (development database, reset by every demo:setup).
DEMO_PASSWORD = "philslist-demo-password"

alice = User.find_or_create_by!(id: ALICE_ID) do |u|
  u.email    = "alice@example.com"
  u.password = DEMO_PASSWORD
end
bob = User.find_or_create_by!(id: BOB_ID) do |u|
  u.email    = "bob@example.com"
  u.password = DEMO_PASSWORD
end

CATEGORIES = {
  "furniture"   => "Furniture",
  "bikes"       => "Bikes",
  "electronics" => "Electronics",
  "housing"     => "Housing",
  "free"        => "Free stuff",
}.freeze

CATEGORIES.each do |slug, name|
  Category.find_or_create_by!(slug: slug) { |c| c.name = name }
end

furniture = Category.find_by!(slug: "furniture")
bikes     = Category.find_by!(slug: "bikes")

# A listing per owner so the board is cross-owner from the first browse.
Listing.find_or_create_by!(title: "Standing desk", owner: alice) do |l|
  l.category   = furniture
  l.body       = "Adjustable-height standing desk, oak top. Moving sale."
  l.price_text = "1500 TL"
  l.status     = "open"
end
Listing.find_or_create_by!(title: "City bike", owner: bob) do |l|
  l.category   = bikes
  l.body       = "Used commuter bike, 7-speed, recently serviced."
  l.price_text = "3000 TL"
  l.status     = "open"
end

puts "Seeded: 2 account holders (#{ALICE_ID}, #{BOB_ID}; sign-in alice@example.com / #{DEMO_PASSWORD}), " \
     "#{Category.count} categories, #{Listing.count} listings."
