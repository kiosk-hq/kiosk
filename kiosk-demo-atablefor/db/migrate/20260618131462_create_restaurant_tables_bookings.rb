# frozen_string_literal: true

# Demo-specific schema: a restaurant table-booking provider (atablefor).
#
# `restaurants` and `table_slots` are open-read (any authenticated principal
# browses availability). `bookings` is owner-scoped via the book_table Action's
# explicit user_id scoping and the my_bookings query's own WHERE predicate.
class CreateRestaurantTablesBookings < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :restaurants do |t|
      t.string :name, null: false
      t.timestamps
    end

    # A bookable table + time-slot: a specific table (with a seat capacity)
    # offered on a given date at a given time. `status` is 'open' until a
    # party claims it, then 'booked'. Availability is the set of open slots.
    create_table :table_slots do |t|
      t.references :restaurant,  null: false, foreign_key: true
      t.string  :table_label,    null: false                     # e.g. "T1", "Window 4"
      t.integer :capacity,       null: false                     # max party size the table seats
      t.date    :slot_date,      null: false
      t.time    :slot_time,      null: false
      t.string  :status,         null: false, default: "open"    # open | booked
      t.timestamps
    end

    create_table :bookings, id: :uuid do |t|
      t.references :user,        null: false, foreign_key: true, type: :uuid
      t.references :restaurant,  null: false, foreign_key: true
      t.references :table_slot,  null: false, foreign_key: true
      t.integer    :party_size,  null: false
      t.string     :status,      null: false, default: "confirmed" # confirmed | cancelled
      t.timestamps
    end

    # Path C — RLS is dropped from this demo. Isolation is app-layer via the
    # book_table Action's explicit `user_id = kiosk.current_user_id()` scoping
    # and the `my_bookings` query's own WHERE predicate. No DB-level row
    # security needed. (atablefor keeps kiosk-rls wired as the baseline data
    # plane but ships no RLS *showcase* task — booking needs no payment nor an
    # RLS beat; getgrocery carries the RLS showcase.)
  end
end
