# frozen_string_literal: true

# A salon chain: salons, the service menu, and appointments booked for a
# service at a salon. An appointment captures the price it was booked at.
class CreateSalonsAndAppointments < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :salons do |t|
      t.string :name, null: false
      # The zone the salon serves in; one operator may list salons in many.
      t.string :timezone, null: false, default: "Europe/Paris"
      t.timestamps
    end

    create_table :services do |t|
      t.string  :name,        null: false
      t.integer :price_cents, null: false # EUR cents
      t.timestamps
    end

    create_table :appointments, id: :uuid do |t|
      t.references  :user,    null: false, foreign_key: true, type: :uuid
      t.references  :salon,   null: false, foreign_key: true
      t.references  :service, foreign_key: true
      t.timestamptz :slot,    null: false
      t.integer     :price_cents # EUR cents, captured at booking
      t.timestamps
    end
  end
end
