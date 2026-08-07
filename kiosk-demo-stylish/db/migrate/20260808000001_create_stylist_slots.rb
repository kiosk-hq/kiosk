# frozen_string_literal: true

# Evergreen availability (K-446): the salon's structure is SEVEN stylists, each
# offering ONE open bookable slot. A stylist_slot is availability — a service +
# a price a named stylist is open to book — NOT a dated appointment, so it never
# goes stale and needs no reseed cron. Bookings (public.appointments) accumulate
# against these slots as visitors book during the demo; the salon starts with
# zero bookings.
#
# The staff `salon_calendar`/forecast reads these slots for the FORECASTED
# revenue (the day's earnings if the open slots fill) and folds in real bookings
# as they happen — a projection computed from real prices, never a fixed number.
class CreateStylistSlots < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :stylist_slots do |t|
      # The stylist (users row, staff_role 'stylist') offering this open slot.
      t.references :stylist, null: false, type: :uuid,
                             foreign_key: { to_table: :users }
      t.references :salon,   null: false, foreign_key: true
      # The service on offer in this slot, and its forecast price (euro cents),
      # captured on the slot so the forecast is a real € figure.
      t.references :service, null: false, foreign_key: true
      t.integer    :price_cents, null: false # EUR cents — the slot's forecast price
      t.string     :label,       null: false # e.g. "Next available with Bea"
      t.timestamps
    end
  end
end
