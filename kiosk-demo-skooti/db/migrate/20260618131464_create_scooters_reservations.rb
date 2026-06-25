# frozen_string_literal: true

# Demo-specific schema: a scooter-rental-shape provider (skooti per Plan 4).
#
# `scooters` is open-read (any authenticated principal browses the fleet).
# `reservations` is owner-scoped — RLS keys off `kiosk.current_user_id()`.
class CreateScootersReservations < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :scooters do |t|
      t.string  :code,               null: false
      t.string  :status,             null: false, default: "available"
      t.decimal :lat,                precision: 10, scale: 6
      t.decimal :lng,                precision: 10, scale: 6
      t.integer :price_per_min_cents, null: false
      t.timestamps
    end

    create_table :reservations, id: :uuid do |t|
      t.references :user,    null: false, foreign_key: true, type: :uuid
      t.references :scooter, null: false, foreign_key: true
      t.string     :status,  null: false, default: "reserved"
      t.timestamptz :started_at
      t.timestamps
    end

    # Path C — RLS is dropped from the demo. Isolation is app-layer via the
    # Actions' explicit `user_id = kiosk.current_user_id()` predicates and
    # the `my_reservations` query's own WHERE. No DB-level row security needed.
  end
end
