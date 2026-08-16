# frozen_string_literal: true

# The TTL row `reserve_room` writes into the ENGINE's `kiosk.reservations` table
# alongside the domain booking — the reserve-then-pay primitive: a hold that
# expires if nobody pays for it.
#
# WHY A MODEL IN THE DEMO for a table kiosk-server owns. The table ships with the
# engine's install generator, but the engine exposes no writer for it, and
# hoteling is the only demo that writes one. While the handler was raw SQL that
# did not show: it was one more `conn.execute`. With K-654 the choice is between
# a model and the last `INSERT` string in the app, so this is the model — named
# for what hoteling uses the row FOR, not for the generic table, because
# `resource_kind` is the column that says which. Promoting it into the engine is
# a public-API decision, not a handler conversion (the UuidCheck/DemoTelemetry
# shape, K-607).
class RoomHold < ApplicationRecord
  self.table_name = "kiosk.reservations"

  # `resource_kind` for hoteling's holds; `resource_id` is the booking's uuid.
  RESOURCE_KIND = "room_booking"

  # How long a reservation holds the room-night before it lapses.
  #
  # The expiry used to be `now() + interval '15 minutes'` — the DATABASE clock.
  # It is the app clock now, because `insert_all` type-casts its values and has
  # no way to pass an SQL expression through. Nothing on the wire exposes
  # `expires_at`, and app and database run on one host in every demo and on the
  # deployed box, so the two clocks are the same clock; if that ever stops being
  # true this constant is where it is written down.
  TTL = 15.minutes
end
