# frozen_string_literal: true

# Kiosk wire surface (controllers shipped by kiosk-server).
# REST endpoints — HTTP method carries semantics (GET = read, POST = write).
#
# Reached from config/routes.rb by Rails' own `draw(:kiosk)`, so the whole wire
# reads as ONE file an operator can copy, instead of being interleaved with this
# app's own pages.
#
# TWO HALVES, and the split is by WHOSE surface it is.
#
# 1. THE PROTOCOL PLANE IS MOUNTED, the ordinary Rails way. `schema`, `pay`, the
#    JWKS and OpenAPI documents, the four kiosk-pop `auth/*` ceremonies, the
#    RFC 8628 device-grant pair, the link/claim/unlink endpoints, the «Link an
#    assistant» pages, the KYC attestation endpoint and the root-relative
#    discovery surface are NOT this operator's to write: their paths and their
#    answers are the spec's. One `mount` line draws them and the gem keeps them
#    in step with the protocol.
#
# 2. THE OPERATOR'S OWN VERBS ARE HAND-WRITTEN, one explicit route each, and the
#    METHOD FOLLOWS THE KIND — GET for a query (a read), POST for an action (a
#    write). That is already what the protocol says a verb IS, so the routes
#    ENCODE the kind instead of being uniform: a verb declared one way and
#    routed the other is a routing error you find by reading this file.
#    `defaults: { kiosk_verb: … }` hands the name to kiosk-server's
#    VerbController — nothing is inferred from the path.
#
# THE MOUNT IS DRAWN FIRST, and that is load-bearing: Rails dispatches the FIRST
# matching route, so every protocol path wins over anything written below it and
# no operator verb can shadow `schema`, `pay` or the auth plane. kiosk-server
# also REFUSES such a declaration at boot
# (Kiosk::Server::HandlerMixin::RESERVED_NAMES), which is where an operator
# actually meets the rule; the ordering is the backstop.
#
# A name nobody registered — and a verb called with the other method — is
# answered by the wire's own 404/405 problem document, from a refusal route
# kiosk-server appends AFTER this file. It can never stand in for a line missing
# here: it refuses, it never serves. `bin/check-verb-routes` derives the list
# below from this app's own handler controllers and fails on a verb with no
# route, a route with no verb, or a method that disagrees with the kind.

mount Kiosk::Server::Engine => Kiosk.configuration.mount_path

# ── The verbs this origin registers ─────────────────────────────────────────
#
# Queries — GET, arguments on the query string.
get  "/kiosk/my_appointments",  to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "my_appointments" }
get  "/kiosk/salons",           to: "kiosk/server/verb#show",   defaults: { kiosk_verb: "salons" }
#
# Actions — POST, a JSON body.
post "/kiosk/book_appointment", to: "kiosk/server/verb#create", defaults: { kiosk_verb: "book_appointment" }
