# frozen_string_literal: true

# Salon staff surface (roles-from-IdP). stylish becomes dual-audience:
# customers book (unchanged), salon STAFF manage the calendar.
#
#   - users.staff_role: 'owner' | 'stylist' | NULL. NULL = a customer (or an
#     assistant account with no login). The role a staff member's session
#     carries — the StubUserIdp reads it to tag the session identity, so the
#     assistant bound at link time inherits it (allowed_roles).
#   - appointments.stylist_id: which staff member (a users row) owns the
#     appointment. NULL for legacy customer bookings. The `salon_calendar`
#     query gates on it: an owner sees ALL of the salon's appointments, a
#     stylist only rows WHERE stylist_id = kiosk.current_user_id().
class AddSalonStaffRoles < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    add_column :users, :staff_role, :string # 'owner' | 'stylist' | NULL

    add_reference :appointments, :stylist,
                  type: :uuid, null: true, foreign_key: { to_table: :users }
  end
end
