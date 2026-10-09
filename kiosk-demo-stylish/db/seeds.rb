# frozen_string_literal: true

# Combette on Park, its evergreen service menu, two visitors and the owner. Every
# service is always bookable and overbooking is allowed, so the salon starts
# with no bookings and never runs out of room. The owner's `staff_role` is the
# role their assistant inherits when they link it.

password = "combette-demo-password"
people = {
  "00000000-0000-0000-0000-000000000001" => ["alice@example.com", nil],
  "00000000-0000-0000-0000-000000000002" => ["bob@example.com", nil],
  "00000000-0000-0000-0000-0000000000a0" => ["owner@combette.example", "owner"],
}.map do |id, (email, staff_role)|
  User.find_or_initialize_by(id:).tap do |person|
    person.email      = email
    person.staff_role = staff_role
    person.password   = password unless person.valid_password?(password)
    person.save!
  end
end

salon = Salon.find_or_create_by!(name: "Combette on Park")

menu = { "Cut" => 3500, "Cut & Blow-dry" => 5000, "Colour" => 9000, "Cut & Colour" => 12_000, "Beard trim" => 2000 }
services = menu.map { |name, price_cents| Service.create_with(price_cents:).find_or_create_by!(name:) }

Rails.logger.info "Seeded: #{people.size} people, #{salon.name} and a #{services.size}-service menu"
