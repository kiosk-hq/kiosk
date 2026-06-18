# frozen_string_literal: true

# Demo-specific schema: a SaaS-booking-shape provider (Combette per spec §2.6).
#
# `salons` is open-read (any authenticated principal browses).
# `appointments` is owner-scoped — RLS keys off `kiosk.current_user_id()`.
#
# Note: RLS isolation across users is NOT verified in this e2e because
# satellite-mode role separation per spec §7.6 isn't shipped in
# kiosk-server yet. The runtime connection uses the migration-owning
# role, which bypasses RLS. The script asserts the wire path
# (Executor → SET LOCAL → SQL → result envelope), not RLS enforcement.
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

    # RLS via the kiosk-rls DSL. The DSL emits ENABLE ROW LEVEL SECURITY,
    # GRANTs to the configured app_role, declares policies, attaches the
    # mandatory comment.
    enable_rls_on :appointments do
      policy :select,
             using: "user_id = kiosk.current_user_id()"
      policy :insert,
             check: "user_id = kiosk.current_user_id() AND kiosk.current_role() = 'customer'"
      comment "Customer's bookings. Visible to the user across all of their agents."
    end

    enable_rls_on :salons do
      policy :select, using: "TRUE" # any authenticated principal may browse
      comment "Salon catalogue. Browse-only via the agent surface; mutations are admin-only."
    end
  end
end
