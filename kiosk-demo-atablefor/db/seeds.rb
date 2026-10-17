# frozen_string_literal: true

# A few Lisbon restaurants with named tables, and two diners who sign in with a
# password. Assistants register themselves on the wire; seatings roll with the
# clock (Restaurant#upcoming_seatings), so nothing here goes stale.

password = 'atablefor-demo-password'
diners = [
  { id: '00000000-0000-0000-0000-000000000001', email: 'diego@example.com', display_name: 'Diego Marlowe' },
  { id: '00000000-0000-0000-0000-000000000002', email: 'bea@example.com',   display_name: 'Bea Ferreira' }
].map do |diner|
  User.find_or_initialize_by(id: diner[:id]).tap do |user|
    user.assign_attributes(diner.except(:id))
    user.password = password unless user.valid_password?(password)
    user.save!
  end
end

# Each table is [label, seats]; average_spend_cents is what one guest spends.
roster = [
  { name: 'Tasca do Tejo',      neighborhood: 'Alfama',        cuisine: 'Portuguese tavern', average_spend_cents: 2200,
    tables: [['Window 6', 2], ['Bar 1', 2], ['Terrace 2', 4], ['Garden 4', 6]] },
  { name: 'Adega da Graça',     neighborhood: 'Graça',         cuisine: 'Grilled fish', average_spend_cents: 3000,
    tables: [['Miradouro 1', 2], ['Nook 3', 2], ['Hall 5', 4], ['Long 8', 8]] },
  { name: 'Cantinho do Bairro', neighborhood: 'Bairro Alto',   cuisine: 'Petiscos & wine', average_spend_cents: 2500,
    tables: [['Counter 2', 2], ['Corner 4', 4], ['Snug 6', 6]] },
  { name: 'Marisqueira Belém',  neighborhood: 'Belém',         cuisine: 'Seafood', average_spend_cents: 4500,
    tables: [['Riverside 3', 2], ['Riverside 4', 2], ['Family 6', 6], ['Banquet 10', 10]] },
  { name: 'Forno do Príncipe',  neighborhood: 'Príncipe Real', cuisine: 'Wood-fired', average_spend_cents: 2800,
    tables: [['Booth 1', 2], ['Booth 2', 2], ['Terrace 5', 5], ['Chef 4', 4]] }
]

roster.each do |entry|
  restaurant = Restaurant.create_with(entry.slice(:neighborhood, :cuisine, :average_spend_cents)).find_or_create_by!(name: entry[:name])
  entry[:tables].each do |label, capacity|
    RestaurantTable.create_with(capacity:).find_or_create_by!(restaurant:, label:)
  end
end

Rails.logger.info "Seeded: #{diners.size} diners, #{roster.size} restaurants, #{RestaurantTable.count} tables"
