# frozen_string_literal: true

# Migration 002 — Kiosk identity tables: agents, agent_tokens, agent_mappings.
# See implementation-plan §3 and design-spec §6.1, §6.4, §6.5.
class CreateKioskIdentityTables < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute Kiosk::Server::SchemaDefinitions.identity_tables_sql(
      schema:       "kiosk",
      user_id_type: :uuid,
      user_table:   "users",
    )
  end

  def down
    execute %(DROP TABLE IF EXISTS "kiosk".agent_mappings)
    execute %(DROP TABLE IF EXISTS "kiosk".agent_tokens)
    execute %(DROP TABLE IF EXISTS "kiosk".agents)
  end
end
