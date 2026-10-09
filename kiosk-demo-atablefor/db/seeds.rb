# frozen_string_literal: true

# A few Lisbon restaurants with named tables, and two diners who sign in with a
# password. Assistants register themselves on the wire; seatings roll with the
# clock (app/models/seatings.rb), so nothing here goes stale.

password = "atablefor-demo-password"
diners = [
  { id: "00000000-0000-0000-0000-000000000001", email: "diego@example.com", display_name: "Diego Marlowe" },
  { id: "00000000-0000-0000-0000-000000000002", email: "bea@example.com",   display_name: "Bea Ferreira" },
].map do |diner|
  User.find_or_initialize_by(id: diner[:id]).tap do |user|
    user.assign_attributes(diner.except(:id))
    user.password = password unless user.valid_password?(password)
    user.save!
  end
end

# Each table is [label, seats, no-show hold in EUR settled at the restaurant].
roster = [
  { name: "Tasca do Tejo",      neighborhood: "Alfama",        cuisine: "Portuguese tavern",
    tables: [["Window 6", 2, 10], ["Bar 1", 2, 0], ["Terrace 2", 4, 10], ["Garden 4", 6, 0]] },
  { name: "Adega da Graça",     neighborhood: "Graça",         cuisine: "Grilled fish",
    tables: [["Miradouro 1", 2, 12], ["Nook 3", 2, 0], ["Hall 5", 4, 0], ["Long 8", 8, 15]] },
  { name: "Cantinho do Bairro", neighborhood: "Bairro Alto",   cuisine: "Petiscos & wine",
    tables: [["Counter 2", 2, 0], ["Corner 4", 4, 8], ["Snug 6", 6, 0]] },
  { name: "Marisqueira Belém",  neighborhood: "Belém",         cuisine: "Seafood",
    tables: [["Riverside 3", 2, 15], ["Riverside 4", 2, 15], ["Family 6", 6, 0], ["Banquet 10", 10, 20]] },
  { name: "Forno do Príncipe",  neighborhood: "Príncipe Real", cuisine: "Wood-fired",
    tables: [["Booth 1", 2, 0], ["Booth 2", 2, 0], ["Terrace 5", 5, 12], ["Chef 4", 4, 10]] },
]

roster.each do |entry|
  restaurant = Restaurant.create_with(entry.slice(:neighborhood, :cuisine)).find_or_create_by!(name: entry[:name])
  entry[:tables].each do |label, capacity, deposit_eur|
    RestaurantTable.create_with(capacity:, deposit_eur:).find_or_create_by!(restaurant:, label:)
  end
end

Rails.logger.info "Seeded: #{diners.size} diners, #{roster.size} restaurants, #{RestaurantTable.count} tables"
