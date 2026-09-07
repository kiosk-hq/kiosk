# frozen_string_literal: true

# appointments.slot — from `timestamp without time zone` to `timestamp with
# time zone`, so the column carries the thing the demo says it carries.
#
# WHY. stylish's whole argument after K-1345 is that an instant must never
# depend on an ambiguous environmental zone: {SalonClock} names Europe/Paris
# once, a wire `slot` with no offset is read AT THE SALON rather than in the
# server process's zone, and every published instant is rendered back on that
# clock. The column underneath was the one place in the fleet that carried no
# zone at all — atablefor's `seating_at` and getgrocery's `slot_at` are both
# `timestamptz` — so the invariant rested on `ActiveRecord.default_timezone`
# being `:utc` rather than on the schema (K-1373).
#
# It was CORRECT, and that is why this is an alignment and not a repair: with
# the default in force every value went in as UTC and came back as the same
# instant. What it was not is SELF-EVIDENT. A reader of `db/structure.sql` saw
# a naive column and had to know a Rails default to work out which instant a row
# meant; an operator who set `ActiveRecord.default_timezone = :local` — one line
# in an initializer, and a legitimate thing to want — would have shifted every
# stored appointment silently, with no error anywhere and no way to tell from
# the data which vintage a row was written in.
#
# THE CAST NAMES THE OLD MEANING EXPLICITLY. `USING slot AT TIME ZONE 'UTC'`
# reads each naive value as the UTC instant it was written as, which is what
# `default_timezone = :utc` made it. Without the USING clause Postgres would
# interpret the values in the SESSION's TimeZone, and a migration run on a box
# set to Europe/Paris would move every appointment by an hour or two. That is
# the same class of bug the column type is being changed to close, so it must
# not be introduced by the change itself.
class ChangeAppointmentSlotToTimestamptz < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute <<~SQL.squish
      ALTER TABLE appointments
        ALTER COLUMN slot TYPE timestamp with time zone
        USING slot AT TIME ZONE 'UTC'
    SQL
  end

  # Back to the shape that shipped, reading the instants back out as UTC — the
  # exact inverse, so a rollback lands on the values it started from rather than
  # on the ones the session's zone happens to name.
  def down
    execute <<~SQL.squish
      ALTER TABLE appointments
        ALTER COLUMN slot TYPE timestamp without time zone
        USING slot AT TIME ZONE 'UTC'
    SQL
  end
end
