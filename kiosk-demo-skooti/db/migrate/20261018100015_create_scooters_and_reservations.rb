# frozen_string_literal: true

# A micromobility operator: a fleet of vehicles, and reservations of one by a
# rider. Isolation is app-layer: every verb scopes by
# `user_id = kiosk.current_user_id()`.
class CreateScootersAndReservations < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    enable_extension "btree_gist"

    create_table :scooters do |t|
      t.string  :code,   null: false
      t.string  :name,   null: false
      # A motorcycle needs the rider's `age_over_18` and `licence_a` attestations.
      t.string  :kind,   null: false, default: "scooter" # scooter | motorcycle
      t.string  :dock,   null: false
      t.decimal :lat, precision: 10, scale: 6, null: false
      t.decimal :lng, precision: 10, scale: 6, null: false
      t.integer :price_per_min_cents, null: false
      t.timestamps
    end

    create_table :reservations, id: :uuid do |t|
      t.references :user,    null: false, foreign_key: true, type: :uuid
      t.references :scooter, null: false, foreign_key: true
      t.string     :status,  null: false, default: "reserved"
      # unpaid → paying → paid. `paying` is claimed atomically before the
      # capture, so a ride is never captured twice.
      t.string     :payment_status, null: false, default: "unpaid"
      t.timestamps
      # The vehicle is held until then: to pay and start, then while the rental token is valid.
      t.datetime   :held_until, null: false

      # One live hold per vehicle.
      t.exclusion_constraint "scooter_id WITH =, tsrange(created_at, held_until) WITH &&",
                             using: :gist, name: "reservations_one_hold_per_scooter"
    end
  end
end
