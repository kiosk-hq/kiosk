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
  example_params({})
  example_row({ id: 1, name: "Combette on Park" })
  def salons
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
  example_params({})
  example_row({ id: 1, salon_id: 1, slot: "2026-06-15T14:00:00Z" })
  def my_appointments
    render json: ActiveRecord::Base.connection.execute(
      "SELECT id, salon_id, slot FROM appointments " \
      "WHERE user_id = kiosk.current_user_id() " \
      "ORDER BY id",
    ).to_a
  end
end
