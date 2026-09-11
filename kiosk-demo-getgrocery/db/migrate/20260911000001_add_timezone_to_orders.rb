# frozen_string_literal: true

# ── THE CLOCK AN ORDER IS QUOTED ON IS RECORDED ON THE ORDER ────────────────
#
# getgrocery times a delivery window at the DOOR: the zone belongs to the served
# Dublin district the delivery address routes to (`DublinZones::ZONES`), and that
# district is resolved once, by the verb that writes the order. This column is
# where the answer lands, so every later reader reads a recorded fact instead of
# re-running the address parser over stored free text. An address that no longer
# resolves — hand-edited, restored from a dump, migrated in from elsewhere —
# would otherwise hand the render the ORIGIN default with nothing saying so, and
# the window would be read out on a clock nobody chose.
#
# WHY THE ZONE AND NOT THE DISTRICT. The district is a routing key; the zone is
# what the customer is TOLD — «08:00-10:00 (Europe/Dublin)». Recording the key
# and deriving the clock through the map on every read would let an edit to that
# map change what an already-placed order says it was booked for. The zone is the
# operational fact; store the fact.
#
# TWO STATEMENTS, AND THE SECOND IS THE ONE THAT MATTERS.
#
# The ADD carries the origin default so every row already in the table is filled
# with what it was actually quoted on: every district this shop serves is on
# `Europe/Dublin` — `DublinZones::ZONES` has one value and
# `spec/delivery_slots_spec.rb` holds it to one — and no order exists for a
# district it does not serve, because `WireArguments.served_district` refuses the
# address first. The backfill states a fact rather than inventing one.
#
# Then the default is DROPPED, and that is the point rather than tidiness. An
# order is written by one verb, and that verb holds the zone before it writes
# anything. A surviving default would let an INSERT that names no clock succeed
# and silently claim Dublin — the same silent default this column exists to end,
# moved one layer down. With no default the column is NOT NULL and unfilled, so
# such an INSERT raises, and every task that places an order is a gate on it.
class AddTimezoneToOrders < ActiveRecord::Migration[8.1]
  def change
    add_column :orders, :timezone, :string, null: false, default: "Europe/Dublin"
    change_column_default :orders, :timezone, from: "Europe/Dublin", to: nil
  end
end
