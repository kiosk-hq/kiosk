# frozen_string_literal: true

# The protocol plane is mounted first, so no verb below can shadow it. Each
# verb this origin declares gets one route: GET for a query, POST for an action.

mount Kiosk::Server::Engine => Kiosk.configuration.mount_path

get  "/kiosk/availability",     to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "availability" }
get  "/kiosk/my_appointments",  to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "my_appointments" }
get  "/kiosk/salon_calendar",   to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "salon_calendar" }
get  "/kiosk/salons",           to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "salons" }
get  "/kiosk/service_menu",     to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "service_menu" }

post "/kiosk/book_appointment", to: "kiosk/server/verb#create", defaults: { kiosk_verb: "book_appointment" }
