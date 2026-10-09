# frozen_string_literal: true

# An Amsterdam fleet priced in EUR cents per minute, and two riders who sign in
# with a password. Assistants register themselves on the wire.

password = "skooti-demo-password"
riders = { "00000000-0000-0000-0000-000000000001" => "ada@example.com",
           "00000000-0000-0000-0000-000000000002" => "ben@example.com" }.map do |id, email|
  User.find_or_initialize_by(id:).tap do |rider|
    rider.email    = email
    rider.password = password unless rider.valid_password?(password)
    rider.save!
  end
end

# SK-001 is created first, so it is the first row scooters_available lists.
scooters = [
  { code: "SK-001", name: "Jordaan Jet",   dock: "Jordaan Dock",       lat: 52.3739, lng: 4.8809 },
  { code: "SK-002", name: "Canal Cruiser", dock: "Jordaan Dock",       lat: 52.3741, lng: 4.8811 },
  { code: "SK-003", name: "Vondel Vespa",  dock: "Jordaan Dock",       lat: 52.3743, lng: 4.8813 },
  { code: "SK-004", name: "Amstel Arrow",  dock: "Prinsengracht Pier", lat: 52.3667, lng: 4.8836 },
  { code: "SK-005", name: "Prinsen Pixie", dock: "Prinsengracht Pier", lat: 52.3669, lng: 4.8838 },
].map do |scooter|
  Scooter.create_with(scooter.merge(status: "available", kind: "scooter", needs_licence: false, price_per_min_cents: 15))
         .find_or_create_by!(code: scooter[:code])
end

motorcycle = Scooter.create_with(name: "Amstel Cruiser", dock: "Amstel Garage", status: "available", kind: "motorcycle",
                                 needs_licence: true, lat: 52.3600, lng: 4.9020, price_per_min_cents: 40)
                    .find_or_create_by!(code: "MC-001")

Rails.logger.info "Seeded: #{riders.size} riders, #{scooters.size} licence-free scooters and the KYC-gated #{motorcycle.name}"
