# frozen_string_literal: true

# Salon staff surface (roles-from-IdP). stylish becomes dual-audience:
# customers book (unchanged), salon STAFF manage the calendar.
#
#   - users.staff_role: 'owner' | NULL. NULL = a customer (or an assistant
#     account with no login). The role a staff member's session carries — the
#     Devise user-IdP reads it (through User#kiosk_role) to tag the session
#     identity, so the assistant bound at link time inherits it
#     (allowed_roles). 'stylist' is NOT a value: `c.roles` is %i[customer
#     owner] and nothing writes anything else (K-712h).
#   - appointments.stylist_id was added here for a per-stylist roster but the
#     evergreen redesign dropped the roster; the `salon_calendar` query now
#     gates the owner forecast on staff_role alone. The column was later
#     removed (see 20260730000001_drop_stylist_id_from_appointments) — this
#     already-run migration keeps adding it so the migration history stays
#     replayable, and the later drop reverses it.
class AddSalonStaffRoles < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    add_column :users, :staff_role, :string # 'owner' | NULL (see the header)

    add_reference :appointments, :stylist,
                  type: :uuid, null: true, foreign_key: { to_table: :users }
  end
end
