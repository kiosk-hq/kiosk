# frozen_string_literal: true

# K-446 (atablefor half) — reshape the single-restaurant, date-offset-seeded
# model into a FINITE restaurant AGGREGATOR with ROLLING-CURRENT seatings.
#
# WHY: the old `table_slots` carried a fixed (slot_date, slot_time) seeded at a
# DATE OFFSET from seed-time, so the hosted deploy went stale (availability
# empty once the seed dates passed). The new model separates the STATIC
# physical table (a restaurant's named table — never stale) from the seating
# DATETIME, which is computed rollingly relative to NOW in Europe/Lisbon (see
# app/models/seatings.rb). A booking pins the actual seating instant it claimed.
#
# Changes:
#   - restaurants gains `cuisine` (aggregator filter/context; neighborhood
#     already exists from AddRealisticBookingColumns).
#   - `table_slots` (date-bearing) is REPLACED by `restaurant_tables` (static:
#     restaurant_id, label, capacity, deposit_eur). A table is bookable for ANY
#     upcoming seating and reused across seatings — a table taken tonight at
#     19:00 is still open tomorrow at 19:00.
#   - `bookings` drops `table_slot_id`, gains `restaurant_table_id` (the physical
#     table) + `seating_at` (timestamptz — the exact seating instant booked).
#     A UNIQUE index on (restaurant_table_id, seating_at) among confirmed rows
#     is what makes a seating sell out: two agents can't confirm the same table
#     for the same seating (finite contention).
class ReshapeAtableforAggregator < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    # Old date-bearing slot table (and its FK from bookings) go away.
    remove_reference :bookings, :table_slot, foreign_key: true
    drop_table :table_slots

    add_column :restaurants, :cuisine, :string

    # Static physical tables — no date. A restaurant offers each of these for
    # every upcoming seating; a confirmed booking on (table, seating_at) claims
    # it for exactly that seating.
    create_table :restaurant_tables do |t|
      t.references :restaurant, null: false, foreign_key: true
      t.string  :label,       null: false               # e.g. "Window 6", "Terrace 2"
      t.integer :capacity,    null: false               # seats
      t.integer :deposit_eur, null: false, default: 0   # DISPLAY-ONLY no-show hold (EUR)
      t.timestamps
    end
    add_index :restaurant_tables, %i[restaurant_id label], unique: true

    # A booking now pins the physical table + the exact seating instant.
    add_reference :bookings, :restaurant_table, foreign_key: true
    add_column    :bookings, :seating_at, :timestamptz

    # The finite-contention guard: at most ONE confirmed booking per
    # (table, seating). A cancelled row frees the seating (status <> 'confirmed'
    # is excluded), so re-booking after a cancel is allowed.
    add_index :bookings, %i[restaurant_table_id seating_at],
              unique: true, where: "status = 'confirmed'",
              name: "idx_bookings_confirmed_table_seating"
  end

  def down
    remove_index  :bookings, name: "idx_bookings_confirmed_table_seating"
    remove_column :bookings, :seating_at
    remove_reference :bookings, :restaurant_table, foreign_key: true
    drop_table :restaurant_tables
    remove_column :restaurants, :cuisine

    create_table :table_slots do |t|
      t.references :restaurant, null: false, foreign_key: true
      t.string  :table_label, null: false
      t.integer :capacity,    null: false
      t.date    :slot_date,   null: false
      t.time    :slot_time,   null: false
      t.string  :status,      null: false, default: "open"
      t.integer :deposit_eur, null: false, default: 0
      t.timestamps
    end
    add_reference :bookings, :table_slot, foreign_key: true
  end
end
