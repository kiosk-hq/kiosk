# frozen_string_literal: true

# Rents SK-001 the way an assistant does — register, reserve, pay, start the
# rental — and prints the rental as one JSON line. bin/make-qr and
# bin/ble-unlock hand its token to a real lock. SERVER_URL is the origin's
# issuer, which registration and the mandates name.
#
#   SERVER_URL=http://localhost:3004 bundle exec ruby script/rental_flow.rb

require "json"
require "securerandom"
require "kiosk/redteam"

issuer = ENV.fetch("SERVER_URL")
client = Kiosk::Redteam::Client.new(base_url: issuer)
rider  = client.register!(name: "rider")

reservation = client.run(rider, name: "reserve", scooter_code: "SK-001")
abort "reserve: #{reservation.status} #{reservation.body}" unless reservation.status == 200
reservation_id = reservation.body.fetch("reservation_id")
price          = reservation.body.fetch("price_per_min_cents")

now     = Time.now.to_i
mandate = { user_id: rider.user_id, agent_id: rider.agent_id, iss: issuer, currency: "eur", iat: now, exp: now + 600 }
intent  = mandate.merge(id: SecureRandom.uuid, scope: "mobility", cap_amount_cents: price)
cart    = mandate.merge(id: SecureRandom.uuid, intent_mandate_id: intent[:id], total_amount_cents: price,
                        line_items: [{ qty: 1, price_cents: price, reservation_id: }])
paid = client.pay(rider, intent:, cart:)
abort "pay: #{paid.status} #{paid.body}" unless paid.status == 200

rental = client.run(rider, name: "start_rental", reservation_id:)
abort "start_rental: #{rental.status} #{rental.body}" unless rental.status == 200

puts JSON.generate(rental.body.merge("reservation_id" => reservation_id))
