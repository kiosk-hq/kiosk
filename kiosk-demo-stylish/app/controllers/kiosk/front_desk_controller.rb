# frozen_string_literal: true

# stylish's READ surface: the five verbs an assistant reaches with
# `POST /kiosk/query`. Kiosk ships a MIXIN, not a base class — the superclass is
# this app's own ApplicationController, and `include Kiosk::Query` is the whole
# contract. Each class-level macro records a declaration and the NEXT `def`
# claims it, so a method with no macros above it is a helper the wire cannot see.
#
# A controller declares queries OR actions, never both — the verb it is reached
# by is a property of the class — so the write half lives next door in
# Kiosk::AppointmentsController. Nothing here is shared with it: the only logic
# both sides need is EUR formatting, which is a Service model method
# (Service.format_eur) and was never controller code.
#
# NOT ROUTABLE. config/routes.rb draws nothing at this controller: handlers are
# reached only through the wire, which is where authentication, the registration
# PoW gate and the GUC-scoped transaction live. A route drawn straight here
# would bypass all three, and the mixin answers such a request 404.
class Kiosk::FrontDeskController < ApplicationController
  include Kiosk::Query

  # salons — full salon catalogue; no per-user scoping, any authenticated
  # principal may browse (mirrors the public SELECT policy previously in RLS).
  description "Browse the public salon catalogue. Each row carries a `salon_id`; pass it to book_appointment as `salon_id`."
  # A verb that takes nothing still declares the empty closed object, so "this
  # verb takes no arguments" is a published fact rather than an absence an
  # assistant has to interpret.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  def salons
    render json: ActiveRecord::Base.connection.execute(
      "SELECT id AS salon_id, name FROM salons ORDER BY id",
    ).to_a
  end

  # service_menu — the salon's public service menu with EUR prices. Any
  # authenticated principal may read it; an assistant uses it to pick a
  # service_id (and see the € price) before booking.
  description "Browse the salon's service menu with EUR prices (name, price_cents, price_eur). " \
              "Takes no parameters and returns the whole menu (small; not paginated); each row carries a " \
              "`service_id` — pass it to book_appointment as `service_id`, where its EUR price is captured on the booking."
  input_schema type: "object",
               additionalProperties: false,
               properties: {},
               required: []
  example_params({})
  example_row({
    service_id: 1, name: "Cut", price_cents: 3500,
    currency: "EUR", price_eur: "€35",
  })
  def service_menu
    render json: ActiveRecord::Base.connection.execute(
      "SELECT id AS service_id, name, price_cents FROM services ORDER BY price_cents",
    ).to_a.map { |row|
      row.merge("currency" => "EUR", "price_eur" => Service.format_eur(row["price_cents"]))
    }
  end

  # availability — the salon's EVERGREEN availability (K-446). Every service on
  # the menu is ALWAYS bookable: infinite capacity, overbooking allowed, nothing
  # to fill up or go stale, no reseed cron. So availability IS the service menu,
  # every row flagged `open: true`. Any authenticated principal (a visitor's
  # assistant) reads it to pick a service to book. Each row carries a `service_id`
  # — pass it to book_appointment to book that service (its EUR price is captured).
  description "Browse the salon's OPEN services — every menu service is always bookable (evergreen, infinite capacity; the salon never fills up). " \
              "Takes no parameters. Each row carries a `service_id` and `open: true` — pass the id to " \
              "book_appointment to book that service (its EUR price is captured on the booking)."
  input_schema type: "object",
               additionalProperties: false,
               properties: {},
               required: []
  example_params({})
  example_row({
    service_id: 3, service: "Colour", open: true,
    currency: "EUR", price_cents: 9000, price_eur: "€90",
  })
  def availability
    render json: ActiveRecord::Base.connection.execute(
      "SELECT id AS service_id, name AS service, price_cents FROM services ORDER BY price_cents",
    ).to_a.map { |row|
      row.merge("open" => true, "currency" => "EUR",
                "price_eur" => Service.format_eur(row["price_cents"]))
    }
  end

  # my_appointments — per-user appointment list scoped by the session GUC.
  # App-layer isolation: the agent supplies no filter; the WHERE is
  # provider-controlled and cannot be bypassed by the caller.
  description "List this principal's appointments (scoped to authenticated user via kiosk.current_user_id())"
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  def my_appointments
    render json: ActiveRecord::Base.connection.execute(
      "SELECT id, salon_id, slot FROM appointments " \
      "WHERE user_id = kiosk.current_user_id() " \
      "ORDER BY id",
    ).to_a
  end

  # salon_calendar — STAFF forecast, role-gated (roles-from-IdP).
  # Reads kiosk.current_role() (the GUC set from the token's role claim, which a
  # staff assistant inherited from the bound human's IdP role):
  #
  #   owner → the WHOLE book: every booking made so far (across all visitors),
  #           plus a FORECAST summary — the € revenue SUMMED from those bookings'
  #           captured prices. Starts at €0 and grows as visitors book.
  #   any other role (customer, or none) → ONLY their OWN bookings
  #           (rows WHERE user_id = kiosk.current_user_id()), and NO forecast.
  #
  # The gate is un-bypassable: an agent can neither self-select `owner` at binding
  # nor pass a wider filter — the role rides the token (from the bound human's
  # IdP), not the request args, and the WHERE is provider-controlled. The forecast
  # is computed live from the real per-booking prices — never a hardcoded number.
  #
  # The gate reads the GUC in SQL rather than the mixin's `kiosk_identity`, and
  # deliberately stays that way: the scoping predicate and the branch then agree
  # by construction, and the query keeps working when it is reached outside a wire
  # request (an RLS journey test), where kiosk_identity is nil but the four GUCs
  # are set regardless.
  description "Staff forecast — role-gated: owner sees ALL bookings + a FORECASTED € revenue total (summed from the actual bookings' prices, growing from €0 as visitors book); any other role sees only their own bookings and no forecast (role from the bound human's IdP)"
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  def salon_calendar
    role = ActiveRecord::Base.connection.execute(
      "SELECT kiosk.current_role() AS role",
    ).first["role"]

    # owner → the whole book; anyone else → only their own bookings.
    appt_scope = role == "owner" ? "TRUE" : "a.user_id = kiosk.current_user_id()"

    # BOOKINGS made so far (accumulate as visitors book — zero at the start).
    appt_rows = ActiveRecord::Base.connection.execute(
      "SELECT a.id, a.salon_id, a.slot, " \
      "       a.service_id, s.name AS service, a.price_cents " \
      "FROM appointments a LEFT JOIN services s ON s.id = a.service_id " \
      "WHERE #{appt_scope} ORDER BY a.slot",
    ).to_a.map { |row|
      row.merge("kind" => "booking", "currency" => "EUR",
                "price_eur" => Service.format_eur(row["price_cents"]))
    }

    rows = appt_rows

    # Owner also gets a FORECAST summary: the € revenue summed from the real
    # per-booking prices. A live figure from real rows — not a fixed number; it is
    # €0 before any booking and grows with each one.
    if role == "owner"
      booked_cents = appt_rows.sum { |r| r["price_cents"].to_i }
      rows += [{
        "summary"        => "forecast",
        "bookings"       => appt_rows.size,
        "currency"       => "EUR",
        "forecast_cents" => booked_cents,
        "forecast_eur"   => Service.format_eur(booked_cents),
      }]
    end

    render json: rows
  end
end
