# frozen_string_literal: true

# The e2e origin's READ surface: the two verbs an assistant reaches with
# `GET /kiosk/<query-name>`. Kiosk ships a MIXIN, not a base class — the superclass
# is the generated app's own ApplicationController, and `include Kiosk::Query`
# is the whole contract. Each class-level macro records a declaration and the
# NEXT `def` claims it, so a method with no macros above it is a helper the
# wire cannot see.
#
# A controller declares queries OR actions, never both — the verb it is reached
# by is a property of the class — so the write half lives next door in
# Kiosk::BookingsController. Both are named in `c.handlers` in
# config/initializers/kiosk.rb; without that line the engine has nothing to
# register from and the origin serves no verbs at all (K-761).
#
# NOT ROUTABLE BY HAND. config/routes.rb draws nothing at this controller by
# name: handlers are reached only through the wire, which is where
# authentication, the registration PoW gate and the GUC-scoped transaction
# live. A route drawn straight here would bypass all three, and the mixin
# answers such a request 404. What routes.rb DOES draw is the wire's own
# per-verb pair (`GET /kiosk/:kiosk_verb`), which resolves the name against
# the registry and reaches these actions through the gates, not around them.
#
# The SQL here is deliberately RAW and deliberately unchanged from the
# registered blocks this file replaces (T-081). `my_appointments` is the
# harness's headline security assertion — per-principal isolation with no RLS —
# and it is the SQL-side `kiosk.current_user_id()` predicate that proves it, so
# rewriting it as an ActiveRecord scope in the same change that moves the verb
# onto the mixin would leave the gate re-proving the rewrite rather than
# checking the move.
class Kiosk::CatalogController < ApplicationController
  include Kiosk::Query

  # salons — public catalog. Any authenticated agent can browse. No per-user
  # scoping: the WHERE is provider-controlled and always TRUE.
  description "Browse the salons this provider takes bookings for. Returns the " \
              "complete public catalogue (small; not paginated) — every salon " \
              "listed here is bookable. Once the human picks one, `book_appointment` " \
              "reserves a slot at it."
  # A verb that takes nothing still declares the empty closed object, so "this
  # verb takes no arguments" is a published fact rather than an absence an
  # assistant has to interpret.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "The complete public catalogue.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    id:   { type: "integer", description: "Pass to book_appointment as `salon_id`." },
                    name: { type: "string", description: "Salon name." },
                  },
                  required: %w[id name],
                }
  example_params({})
  example_row({ id: 1, name: "Combette on Park" })
  def salons
    # §3.7.4, THE ONE CACHE PERMISSION THE SPEC GIVES AN OPERATOR, exercised
    # here because this verb is its worked example: "the default for a `200` is
    # `private, no-store`; an operator MAY relax it to `private, max-age=N` for
    # a payload that is genuinely identity-independent — a public catalogue,
    # say". This IS the public catalogue: the WHERE above is provider-
    # controlled and always true, so every caller gets the same rows and an
    # assistant that keeps them for a minute is not holding somebody else's
    # data. It is also how an assistant's own cache saves a toll — a response
    # still fresh is never re-requested and therefore never re-challenged.
    #
    # It reaches the wire only because K-823 fixed the seam: {HandlerDispatch}
    # used to drop the sub-response's headers, which made this permission
    # unreachable from the one kind of code an operator writes. `my_appointments`
    # below sets nothing and keeps `private, no-store` — the control, and the
    # honest policy for a per-principal payload.
    response.headers["Cache-Control"] = "private, max-age=60"
    render json: ActiveRecord::Base.connection.execute(
      "SELECT id, name FROM salons ORDER BY id",
    ).to_a
  end

  # my_appointments — per-user appointment list scoped by the session GUC.
  # The WHERE is provider-controlled; the agent supplies no user filter.
  # App-layer per-user isolation without RLS: the principal sees only rows
  # where user_id matches kiosk.current_user_id(), enforced in the query.
  description "List the appointments belonging to the authenticated principal. " \
              "The caller cannot widen this: the scope is the provider's, taken " \
              "from the authenticated session, so another principal's bookings " \
              "are never returned. Returns the complete set (not paginated)."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema type: "array",
                description: "The principal's own appointments, complete and not paginated.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    id:       { type: "string", description: "uuid — the appointment. book_appointment calls the same value `appointment_id`." },
                    salon_id: { type: "integer", description: "The salon booked." },
                    slot:     { type: "string", description: "Appointment time, ISO 8601." },
                  },
                  required: %w[id salon_id slot],
                }
  example_params({})
  # A UUID, because `appointments.id` IS a uuid (`create_table :appointments,
  # id: :uuid`) and the `output_schema` above says so. It published `1` until
  # 2026-08-20, when e2e/schema_conformance.rb — the first thing ever to check
  # a descriptor's examples against that descriptor's own schemas (§8.3,
  # matrix SPEC-084) — refused it on its first run. An assistant that copied
  # this row verbatim built an integer id for a value the wire never returns
  # as one. K-825.
  example_row({ id: "3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f", salon_id: 1,
                slot: "2026-06-15T14:00:00Z" })
  def my_appointments
    render json: ActiveRecord::Base.connection.execute(
      "SELECT id, salon_id, slot FROM appointments " \
      "WHERE user_id = kiosk.current_user_id() " \
      "ORDER BY id",
    ).to_a
  end
end
