# frozen_string_literal: true

# The protocol plane is mounted first, so no verb below can shadow it. Each
# verb this origin declares gets one route: GET for a query, POST for an action.

mount Kiosk::Server::Engine => Kiosk.configuration.mount_path

get  "/kiosk/availability",    to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "availability" }
get  "/kiosk/hotel_detail",    to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "hotel_detail" }
get  "/kiosk/my_bookings",     to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "my_bookings" }
get  "/kiosk/properties",      to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "properties" }
get  "/kiosk/search_hotels",   to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "search_hotels" }

post "/kiosk/confirm_booking", to: "kiosk/server/verb#create", defaults: { kiosk_verb: "confirm_booking" }
post "/kiosk/reserve_room",    to: "kiosk/server/verb#create", defaults: { kiosk_verb: "reserve_room" }
