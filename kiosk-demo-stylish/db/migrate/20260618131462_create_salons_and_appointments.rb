# frozen_string_literal: true

# Demo-specific schema: a salon-booking-shape provider.
#
# Under Path C, RLS is OPTIONAL and this demo drops it. App-layer isolation
# is provided instead:
#   - `book_appointment` Action scopes INSERT to kiosk.current_user_id()
#   - `my_appointments` named Query filters WHERE user_id = kiosk.current_user_id()
#   - `salons` named Query is open-read (no per-user filter needed)
class CreateSalonsAndAppointments < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :salons do |t|
      t.string :name, null: false
      t.timestamps
    end

    create_table :appointments, id: :uuid do |t|
      t.references :user,  null: false, foreign_key: true, type: :uuid
      t.references :salon, null: false, foreign_key: true
      t.timestamp  :slot,  null: false
      t.timestamps
    end
  end
end
