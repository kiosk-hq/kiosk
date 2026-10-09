# frozen_string_literal: true

# The protocol plane is mounted first, so no verb below can shadow it. Each
# verb this origin declares gets one route: GET for a query, POST for an action.

mount Kiosk::Server::Engine => Kiosk.configuration.mount_path

get  "/kiosk/my_reservations",    to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "my_reservations" }
get  "/kiosk/scooters_available", to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "scooters_available" }

post "/kiosk/rent_motorcycle",    to: "kiosk/server/verb#create", defaults: { kiosk_verb: "rent_motorcycle" }
post "/kiosk/reserve",            to: "kiosk/server/verb#create", defaults: { kiosk_verb: "reserve" }
post "/kiosk/start_rental",       to: "kiosk/server/verb#create", defaults: { kiosk_verb: "start_rental" }
