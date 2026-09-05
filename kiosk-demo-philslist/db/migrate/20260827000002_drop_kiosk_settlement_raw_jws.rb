# frozen_string_literal: true

# kiosk.settlements.raw_jws — delivering a REMOVAL to databases that already
# carry the column.
#
# `raw_jws` is gone from the canonical DDL — a settlement is a SERVER-minted
# receipt, nobody signs it, so there is no signature to store — and gone from
# the INSERT in
# `kiosk-server/lib/kiosk/server/executor.rb#persist_settlement`, whose column
# list names eight columns without it. That change was an edit to the CREATE
# plus a `db/structure.sql` re-dump, and that reaches every database built FROM
# ZERO and no running one.
#
# WHY THAT IS A DEFECT AND NOT HOUSEKEEPING. The older DDL emitted `raw_jws text
# NOT NULL` with NO DEFAULT. So a database provisioned while that vintage was
# head still carries the column, head's INSERT does not name it, and Postgres
# refuses the statement — EVERY settlement INSERT, permanently, on a box that
# has no way to lose the column. `bin/check-migration-replay` reports it as
# HAZARD on 20 schema vintages across the seven demos that have a
# `kiosk.settlements` at all.
#
# THE GENERAL RULE, which is what this file is really for: **a column REMOVED
# from the canonical DDL needs a shipped `DROP` for exactly the same reason a
# column ADDED needs a shipped `ADD`.** The additive half — a column the box
# LACKS that the code SELECTs — is the one everybody remembers; this is the
# subtractive half, a column the box KEEPS that the code will not name, and it
# strands the origin just as hard.
#
# WHY A NEW FILE AND NOT A REPAIR LINE INSIDE MIGRATION 005. The `ALTER TABLE …
# ADD COLUMN IF NOT EXISTS` repairs in `SchemaDefinitions.identity_tables_sql`
# work because a database older than the six kiosk migrations still has all six
# PENDING, so 002 runs there. The databases that carry `raw_jws` are NEWER: they
# have ALREADY recorded `20260820130116`, so 005 will never run again there and
# a repair placed inside it could not reach them. A migration that has shipped
# is never edited; a change arrives as a new file.
#
# GUARDED, for the same reason those repairs are: a from-zero database — every
# gate, every laptop, and every box `deploy/demo-reset.sh` has rebuilt — never
# had the column, so this must be a no-op there rather than an error that strands
# every later migration.
class DropKioskSettlementRawJws < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute %(ALTER TABLE "kiosk".settlements DROP COLUMN IF EXISTS raw_jws)
  end

  # Restores the exact shape the column shipped with — `text NOT NULL`, no
  # default — so a rollback lands on the schema that shipped, walls and all. The
  # VALUES are not restored and cannot be: `persist_settlement` set every one of
  # them to `''`, an empty string published as a signature, which is why the
  # column went.
  def down
    return if column_exists?("kiosk.settlements", :raw_jws)

    execute %(ALTER TABLE "kiosk".settlements ADD COLUMN raw_jws text NOT NULL DEFAULT '')
    execute %(ALTER TABLE "kiosk".settlements ALTER COLUMN raw_jws DROP DEFAULT)
  end
end
