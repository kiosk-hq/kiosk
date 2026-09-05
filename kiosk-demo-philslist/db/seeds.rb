# frozen_string_literal: true

# Seeds the philslist classifieds board:
#   - two account holders, Alice and Bob, with STABLE UUIDs and real Devise
#     credentials. The credentials are the load-bearing part: no driver can hand
#     itself a principal, so every one of them signs its human
#     in through the real /users/sign_in form and binds an assistant through the
#     shipped ceremony (register → link → claim, script/bound_assistant.rb). The
#     UUIDs stay stable because the claim REBINDS the assistant onto the human's
#     account, which is what makes "Alice's rows" mean these ids.
#     Alice's account is ALSO the HOUSEHOLD account: two
#     assistants (Alice's and her partner's) bind to it in `demo:binding`, so a
#     listing either assistant posts is one shared board presence. Bob is a
#     SEPARATE owner — the cross-owner isolation boundary (`demo:isolation`).
#   - the five categories (Bikes, Electronics, Furniture, Housing, Free stuff).
#   - ~7 concrete, NAMED listings across those categories, priced in EUR, split
#     across Alice and Bob so browse_listings is genuinely cross-owner and
#     my_listings has a non-vacuous positive control. Two of Alice's listings
#     carry a created_by_agent_id (household assistants) so the public board
#     shows the SAME account posting through two different assistants.

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

by_slug = Category.all.index_by(&:slug)

# Concrete, named listings so a plain prompt — "post my racing bike for €300",
# "find a used bike under €200" — has a real board to act on. price_text is a
# free-form DISPLAY string ("€300", "Free", NULL): the board never transacts on
# it (there is no `pay` verb). owner drives isolation; agent is the household
# assistant that posted it (nil = posted by the human through the web session).
#
# Alice's account is the HOUSEHOLD: "alices-macbook" and "partner-pixel" are the
# two assistants bound to it in demo:binding — two devices, one shared board
# presence. Bob is the neighbour across the isolation boundary.
LISTINGS = [
  # Alice's household account — posted through two different assistants.
  { owner: alice, agent: "alices-macbook", category: "bikes",       status: "open",
    title: "Carbon road bike — €300",
    body:  "Lightweight carbon road bike, 54cm, Shimano 105 groupset. Recently serviced, new chain. Ideal for racing or fast commutes.",
    price: "€300" },
  { owner: alice, agent: "alices-macbook", category: "furniture",   status: "open",
    title: "Standing desk — €120",
    body:  "Adjustable-height standing desk, solid oak top, electric lift. Moving out, must go this month.",
    price: "€120" },
  { owner: alice, agent: "partner-pixel",  category: "electronics", status: "open",
    title: "Vintage film camera — €180",
    body:  "Classic 35mm rangefinder, fully working, with 50mm lens and leather case. Posted from our shared household account.",
    price: "€180" },
  { owner: alice, agent: nil,              category: "free",        status: "open",
    title: "Moving out: free bookshelf",
    body:  "Pine 5-shelf bookcase, sturdy, some scuffs. Free to whoever can collect this weekend.",
    price: "Free" },

  # Bob's account — the cross-owner side of the isolation boundary.
  { owner: bob,   agent: nil,              category: "bikes",       status: "open",
    title: "City commuter bike — €140",
    body:  "Used 7-speed commuter, mudguards and rack fitted, recently serviced. Great around-town runner.",
    price: "€140" },
  { owner: bob,   agent: nil,              category: "electronics", status: "open",
    title: "Mechanical keyboard — €65",
    body:  "Tenkeyless mechanical keyboard, brown switches, barely used. Comes with braided cable.",
    price: "€65" },
  { owner: bob,   agent: nil,              category: "housing",     status: "open",
    title: "Room in shared flat — €450/mo",
    body:  "Bright double room in a friendly 3-person flat, central, bills included. Available from next month.",
    price: "€450/mo" },
].freeze

LISTINGS.each do |spec|
  Listing.find_or_create_by!(title: spec[:title], owner: spec[:owner]) do |l|
    l.category            = by_slug.fetch(spec[:category])
    l.body                = spec[:body]
    l.price_text          = spec[:price]
    l.status              = spec[:status]
    l.created_by_agent_id = spec[:agent]
  end
end

puts "Seeded: 2 account holders (#{ALICE_ID}, #{BOB_ID}; sign-in alice@example.com / #{DEMO_PASSWORD}), " \
     "#{Category.count} categories, #{Listing.count} listings (prices in EUR)."
