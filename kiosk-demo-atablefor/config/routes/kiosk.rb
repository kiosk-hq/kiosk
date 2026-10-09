# frozen_string_literal: true

# The protocol plane is mounted first, so no verb below can shadow it. Each
# verb this origin declares gets one route: GET for a query, POST for an action.

mount Kiosk::Server::Engine => Kiosk.configuration.mount_path

get  "/kiosk/availability",   to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "availability" }
get  "/kiosk/my_bookings",    to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "my_bookings" }

post "/kiosk/book_table",     to: "kiosk/server/verb#create", defaults: { kiosk_verb: "book_table" }
post "/kiosk/cancel_booking", to: "kiosk/server/verb#create", defaults: { kiosk_verb: "cancel_booking" }
