# frozen_string_literal: true

# Migration 003 — kiosk.actions registry + kiosk.action_log invocation records.
class CreateKioskActionsLog < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute Kiosk::Server::SchemaDefinitions.actions_log_sql(
      schema:       "kiosk",
      user_id_type: :uuid,
    )
  end

  def down
    execute %(DROP TABLE IF EXISTS "kiosk".action_log)
    execute %(DROP TABLE IF EXISTS "kiosk".actions)
  end
end
