# frozen_string_literal: true

# Demo-specific schema: a SaaS-booking-shape provider (Combette per spec §2.6).
#
# `salons` is open-read (any authenticated principal browses) via the
# registered `salons` named query.
# `appointments` is owner-scoped via the `my_appointments` named query
# (WHERE user_id = kiosk.current_user_id()), enforced in app-layer.
#
# Path C: raw SQL removed; isolation is app-layer (named queries), RLS optional.
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
