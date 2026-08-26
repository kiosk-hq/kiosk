# frozen_string_literal: true

# users.display_name — THE NAME A ROSTER PUBLISHES (K-950).
#
# The column is not part of anybody's login, so it does not belong in the shared
# add_devise_columns_to_users that three demos hold byte-identical. tudu is the
# demo that needs it because tudu is the demo whose verbs name OTHER PEOPLE.
# atablefor already ships the same column for the same reason (its public
# reservations board names diners) — see
# 20260729000001_add_realistic_booking_columns.rb — so this is the fleet's shape
# and not a new one.
#
# NULLABLE on purpose, and the null is a real state rather than a defensive one:
# every assistant-created principal is a headless row with no human behind it to
# have chosen anything. {User.public_name} answers that case with an opaque
# pseudonym derived from the account UUID — see the long note there for why the
# UUID and never the address.
#
# WHY ITS OWN FILE, WHICH IS THE POINT OF THIS MIGRATION EXISTING (K-1074).
# It shipped on 2026-08-23 as a line APPENDED to
# 20260719000001_create_tudu_domain.rb — a migration first shipped 2026-07-19
# and long since recorded in every deployed database's `schema_migrations`.
# `db:migrate` never re-runs a recorded version, so the column reached
# `db/structure.sql` and every from-zero database and COULD NOT REACH A RUNNING
# ONE. The result was four HTTP 500s on the live tudu box (`/`, `/lists`,
# `/shared`, `/users/sign_up`), because `lists_controller.rb`'s housemate board
# SELECTs `owner_u.display_name`; the one page that survived was the sign-in
# form, which Devise renders from its own gem template and never names the
# column. A shipped migration is never edited — a change arrives as a new file
# (MIGRATION-AND-CONFIG-UPGRADE-POLICY, Phil 2026-08-20; T-103) — and the guard
# is `bin/check-migration-replay`, which replays the migrations onto a
# pre-existing database and diffs the result against `db/structure.sql`.
#
# GUARDED, AND THE GUARD IS NOT DEFENSIVENESS. Between 2026-08-23 and today the
# column was in `db/structure.sql` while no migration created it, so a database
# provisioned by `db:schema:load` in that window — `deploy/demo-reset.sh` does
# exactly that, and so does `demo:setup` — HAS the column and does NOT have this
# version recorded. Rolling such a box forward must be a no-op here, not a
# `PG::DuplicateColumn` that strands every later migration. Databases that
# predate the window get the column; databases that already have it are left
# alone.
class AddDisplayNameToUsers < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    return if column_exists?(:users, :display_name)

    add_column :users, :display_name, :string
  end

  def down
    remove_column :users, :display_name, if_exists: true
  end
end
