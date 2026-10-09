# frozen_string_literal: true

# The protocol plane is mounted first, so no verb below can shadow it. Each
# verb this origin declares gets one route: GET for a query, POST for an action.

mount Kiosk::Server::Engine => Kiosk.configuration.mount_path

get  "/kiosk/browse_listings", to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "browse_listings" }
get  "/kiosk/my_listings",     to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "my_listings" }

post "/kiosk/close_listing",   to: "kiosk/server/verb#create", defaults: { kiosk_verb: "close_listing" }
post "/kiosk/edit_listing",    to: "kiosk/server/verb#create", defaults: { kiosk_verb: "edit_listing" }
post "/kiosk/post_listing",    to: "kiosk/server/verb#create", defaults: { kiosk_verb: "post_listing" }
