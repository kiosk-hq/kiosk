# frozen_string_literal: true

# The e2e origin's PUBLIC CATALOGUE: the one verb an assistant reaches with
# `GET /kiosk/salons`. Kiosk ships a MIXIN, not a base class — the superclass
# is the generated app's own ApplicationController, and `include Kiosk::Handler`
# is the whole contract. Each class-level macro records a declaration and the
# NEXT `def` claims it, so a method with no macros above it is a helper the
# wire cannot see.
#
# `kind :query` is what puts this verb on `GET`, and it is a property of the
# DECLARATION rather than of the class (K-921): Kiosk::BookingsController next
# door declares a query AND an action, which is the harness's proof that one
# controller can. Both classes are named in `c.handlers` in
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
# registered blocks this file replaces (T-081).
class Kiosk::CatalogController < ApplicationController
  include Kiosk::Handler

  # salons — public catalog. Any authenticated agent can browse. No per-user
  # scoping: the WHERE is provider-controlled and always TRUE.
  kind :query
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
    # (Kiosk::BookingsController) sets nothing and keeps `private, no-store` —
    # the control, and the honest policy for a per-principal payload.
    response.headers["Cache-Control"] = "private, max-age=60"
    render json: ActiveRecord::Base.connection.execute(
      "SELECT id, name FROM salons ORDER BY id",
    ).to_a
  end
end
