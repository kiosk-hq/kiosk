# frozen_string_literal: true

# Drop the vestigial appointments.stylist_id column. The evergreen design has
# no salon staff roster: the `salon_calendar`
# query now gates the owner forecast on staff_role alone (owner sees all,
# customers see their own), and no code path ever reads or writes stylist_id.
# The column, its index, and its FK to users are therefore dead — remove them.
class DropStylistIdFromAppointments < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    remove_reference :appointments, :stylist,
                     type: :uuid, null: true, foreign_key: { to_table: :users }
  end
end
