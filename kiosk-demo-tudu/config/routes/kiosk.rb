# frozen_string_literal: true

# The protocol plane is mounted first, so no verb below can shadow it. Each
# verb this origin declares gets one route: GET for a query, POST for an action.

mount Kiosk::Server::Engine => Kiosk.configuration.mount_path

get  "/kiosk/list_members",  to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "list_members" }
get  "/kiosk/list_todos",    to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "list_todos" }
get  "/kiosk/my_lists",      to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "my_lists" }
get  "/kiosk/whoami",        to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "whoami" }

post "/kiosk/accept_invite", to: "kiosk/server/verb#create", defaults: { kiosk_verb: "accept_invite" }
post "/kiosk/add_todo",      to: "kiosk/server/verb#create", defaults: { kiosk_verb: "add_todo" }
post "/kiosk/complete_todo", to: "kiosk/server/verb#create", defaults: { kiosk_verb: "complete_todo" }
post "/kiosk/create_list",   to: "kiosk/server/verb#create", defaults: { kiosk_verb: "create_list" }
post "/kiosk/invite",        to: "kiosk/server/verb#create", defaults: { kiosk_verb: "invite" }
post "/kiosk/remove_member", to: "kiosk/server/verb#create", defaults: { kiosk_verb: "remove_member" }
