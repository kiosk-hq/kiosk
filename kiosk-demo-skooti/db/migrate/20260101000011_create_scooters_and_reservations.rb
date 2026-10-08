# frozen_string_literal: true

# A micromobility operator: a fleet of vehicles, and reservations of one by a
# rider. Isolation is app-layer: every verb scopes by
# `user_id = kiosk.current_user_id()`.
class CreateScootersAndReservations < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :scooters do |t|
      t.string  :code,   null: false
      t.string  :name
      t.string  :kind,   null: false, default: "scooter" # scooter | motorcycle
      # Renting it needs the rider's `age_over_18` and `licence_a` attestations.
      t.boolean :needs_licence, null: false, default: false
      t.string  :dock
      t.string  :status, null: false, default: "available"
      t.decimal :lat, precision: 10, scale: 6
      t.decimal :lng, precision: 10, scale: 6
      t.integer :price_per_min_cents, null: false
      t.timestamps
    end

    create_table :reservations, id: :uuid do |t|
      t.references  :user,    null: false, foreign_key: true, type: :uuid
      t.references  :scooter, null: false, foreign_key: true
      t.string      :status,  null: false, default: "reserved"
      t.timestamptz :started_at
      # unpaid → paying → paid. `paying` is claimed atomically before the
      # capture, so a ride is never captured twice; the payer is recorded with it.
      t.string      :payment_status,  null: false, default: "unpaid"
      t.uuid        :paid_by_user_id
      t.timestamps
    end
  end
end
