# frozen_string_literal: true

# `kiosk.agents.issuer` on a database whose agents table predates it: the origin
# each assistant account belongs to. Existing rows are backfilled with the
# `c.issuer` in force when this runs. A fresh `kiosk:install` gets the column
# from migration 002 and needs no separate file.
class AddKioskAgentsIssuer < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute Kiosk::Server::SchemaDefinitions.agents_issuer_sql(schema: "kiosk")
  end

  def down
    execute %(DROP INDEX IF EXISTS "kiosk".idx_agents_issuer_public_key_live)
    execute %(CREATE UNIQUE INDEX IF NOT EXISTS idx_agents_public_key_live ON "kiosk".agents (public_key) WHERE revoked_at IS NULL)
    execute %(ALTER TABLE "kiosk".agents DROP COLUMN IF EXISTS issuer)
  end
end
