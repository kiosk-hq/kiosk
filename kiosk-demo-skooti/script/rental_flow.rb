# frozen_string_literal: true

# Rents SK-001 the way an assistant does and prints the rental as one JSON line,
# whose token bin/make-qr and bin/ble-unlock hand to a real lock.
#   SERVER_URL=http://localhost:3004 bundle exec ruby script/rental_flow.rb

require "json"
require "kiosk/test_helpers/assistant"

client = Kiosk::TestHelpers::Assistant.new(base_url: ENV.fetch("SERVER_URL"))
rider  = client.register!

reservation = client.run(rider, name: "reserve", scooter_code: "SK-001")
abort "reserve: #{reservation.status} #{reservation.body}" unless reservation.status == 200
reservation_id = reservation.body.fetch("reservation_id")
price          = reservation.body.fetch("price_per_min_cents")

quote = client.mandates(rider, total: price, scope: "mobility", line_items: [{ qty: 1, price_cents: price, reservation_id: }])
paid  = client.pay(rider, **quote)
abort "pay: #{paid.status} #{paid.body}" unless paid.status == 200

rental = client.run(rider, name: "start_rental", reservation_id:)
abort "start_rental: #{rental.status} #{rental.body}" unless rental.status == 200

puts JSON.generate(rental.body.merge("reservation_id" => reservation_id))
