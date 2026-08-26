# frozen_string_literal: true

# kiosk.settlements.raw_jws — THE REMOVAL K-948 NEVER SHIPPED (K-1086).
#
# `209db0f8` (2026-08-23, K-948) took `raw_jws` out of the canonical DDL — a
# settlement is a SERVER-minted receipt, nobody signs it, so there is no
# signature to store — and out of the INSERT in
# `kiosk-server/lib/kiosk/server/executor.rb#persist_settlement`, whose column
# list now names eight columns without it. It shipped as an edit to the CREATE
# plus a `db/structure.sql` re-dump, and that reaches every database built FROM
# ZERO and no running one.
#
# WHY THAT IS A DEFECT AND NOT HOUSEKEEPING. At `209db0f8^` the same DDL emitted
# `raw_jws text NOT NULL` with NO DEFAULT. So a database provisioned while that
# vintage was head still carries the column, head's INSERT does not name it, and
# Postgres refuses the statement — EVERY settlement INSERT, permanently, on a
# box that has no way to lose the column. `bin/check-migration-replay` reports
# it as HAZARD on 20 schema vintages across the seven demos that have a
# `kiosk.settlements` at all.
#
# THE GENERAL RULE, which is what this file is really for (T-103 clause (vii)):
# **a column REMOVED from the canonical DDL needs a shipped `DROP` for exactly
# the same reason a column ADDED needs a shipped `ADD`.** K-1074 is the additive
# half of the same delivery gap — a column the box LACKS that the code SELECTs;
# this is the subtractive half — a column the box KEEPS that the code will not
# name. Only the additive half was written down.
#
# WHY A NEW FILE AND NOT A REPAIR LINE INSIDE 005. The `ALTER TABLE … ADD COLUMN
# IF NOT EXISTS` repairs in `SchemaDefinitions.identity_tables_sql` work because
# the 2026-08-20 renumbering left all six kiosk migrations PENDING on a
# pre-2026-08-20 database, so 002 runs there. The databases that carry `raw_jws`
# are the ones provisioned 2026-08-20..23, which have ALREADY recorded
# `20260820130116` — 005 will never run again there, and a repair placed inside
# it could not reach them. That is the K-1074 trap one table over. A migration
# that has shipped is never edited; a change arrives as a new file.
#
# GUARDED, for the same reason the K-1074 repair is: a from-zero database — every
# gate, every laptop, and every box `deploy/demo-reset.sh` has rebuilt — never
# had the column, so this must be a no-op there rather than an error that strands
# every later migration.
class DropKioskSettlementRawJws < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute %(ALTER TABLE "kiosk".settlements DROP COLUMN IF EXISTS raw_jws)
  end

  # Restores the exact pre-K-948 shape — `text NOT NULL`, no default — so a
  # rollback lands on the schema that shipped, walls and all. The VALUES are not
  # restored and cannot be: `persist_settlement` set every one of them to `''`,
  # which is the misreading K-876 found published and the reason the column went.
  def down
    return if column_exists?("kiosk.settlements", :raw_jws)

    execute %(ALTER TABLE "kiosk".settlements ADD COLUMN raw_jws text NOT NULL DEFAULT '')
    execute %(ALTER TABLE "kiosk".settlements ALTER COLUMN raw_jws DROP DEFAULT)
  end
end
