# frozen_string_literal: true

# The protocol plane is mounted first, so no verb below can shadow it. Each
# verb this origin declares gets one route: GET for a query, POST for an action.

mount Kiosk::Server::Engine => Kiosk.configuration.mount_path

# ── The verbs this origin registers ─────────────────────────────────────────
#
# Queries — GET, arguments on the query string.
get  "/kiosk/my_appointments",  to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "my_appointments" }
get  "/kiosk/salons",           to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "salons" }
#
# Actions — POST, a JSON body.
post "/kiosk/book_appointment", to: "kiosk/server/verb#create", defaults: { kiosk_verb: "book_appointment" }
