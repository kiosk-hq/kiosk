# frozen_string_literal: true

# A classifieds board split between two sellers who sign in with a password.
# Alice's account is a household: two of her listings were posted by two
# different assistants. Assistants register themselves on the wire.

password = "philslist-demo-password"
alice, bob = { "00000000-0000-0000-0000-000000000001" => "alice@example.com",
               "00000000-0000-0000-0000-000000000002" => "bob@example.com" }.map do |id, email|
  User.find_or_initialize_by(id:).tap do |seller|
    seller.email    = email
    seller.password = password unless seller.valid_password?(password)
    seller.save!
  end
end

categories = { "furniture" => "Furniture", "bikes" => "Bikes", "electronics" => "Electronics",
               "housing" => "Housing", "free" => "Free stuff" }.to_h do |slug, name|
  [slug, Category.create_with(name:).find_or_create_by!(slug:)]
end

[
  { owner: alice, agent: "alices-macbook", category: "bikes", price: "€300",
    title: "Carbon road bike — €300",
    body: "Lightweight carbon road bike, 54cm, Shimano 105 groupset. Recently serviced, new chain. Ideal for racing or fast commutes." },
  { owner: alice, agent: "alices-macbook", category: "furniture", price: "€120",
    title: "Standing desk — €120",
    body: "Adjustable-height standing desk, solid oak top, electric lift. Moving out, must go this month." },
  { owner: alice, agent: "partner-pixel", category: "electronics", price: "€180",
    title: "Vintage film camera — €180",
    body: "Classic 35mm rangefinder, fully working, with 50mm lens and leather case. Posted from our shared household account." },
  { owner: alice, agent: nil, category: "free", price: "Free",
    title: "Moving out: free bookshelf",
    body: "Pine 5-shelf bookcase, sturdy, some scuffs. Free to whoever can collect this weekend." },
  { owner: bob, agent: nil, category: "bikes", price: "€140",
    title: "City commuter bike — €140",
    body: "Used 7-speed commuter, mudguards and rack fitted, recently serviced. Great around-town runner." },
  { owner: bob, agent: nil, category: "electronics", price: "€65",
    title: "Mechanical keyboard — €65",
    body: "Tenkeyless mechanical keyboard, brown switches, barely used. Comes with braided cable." },
  { owner: bob, agent: nil, category: "housing", price: "€450/mo",
    title: "Room in shared flat — €450/mo",
    body: "Bright double room in a friendly 3-person flat, central, bills included. Available from next month." },
].each do |listing|
  Listing.create_with(category: categories.fetch(listing[:category]), body: listing[:body], price_text: listing[:price],
                      created_by_agent_id: listing[:agent])
         .find_or_create_by!(title: listing[:title], owner: listing[:owner])
end

Rails.logger.info "Seeded: 2 sellers, #{Category.count} categories, #{Listing.count} listings"
