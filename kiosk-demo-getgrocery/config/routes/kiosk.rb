# frozen_string_literal: true

# The protocol plane is mounted first, so no verb below can shadow it. Each
# verb this origin declares gets one route: GET for a query, POST for an action.

mount Kiosk::Server::Engine => Kiosk.configuration.mount_path

get  "/kiosk/catalog",             to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "catalog" }
get  "/kiosk/delivery_slots",      to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "delivery_slots" }
get  "/kiosk/my_orders",           to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "my_orders" }

post "/kiosk/create_order",        to: "kiosk/server/verb#create", defaults: { kiosk_verb: "create_order" }
post "/kiosk/reschedule_delivery", to: "kiosk/server/verb#create", defaults: { kiosk_verb: "reschedule_delivery" }
