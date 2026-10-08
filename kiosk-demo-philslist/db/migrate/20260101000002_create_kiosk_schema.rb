# frozen_string_literal: true

# Migration 001 — Kiosk schema + the four current_*() helper functions.
#
# `ActiveRecord::Migration[…]` resolves at host-app load time, so this
# file picks up whatever Rails version the host is on.
class CreateKioskSchema < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute Kiosk::Server::SchemaDefinitions.helper_functions_sql(
      schema:        "kiosk",
      guc_namespace: "app",
      user_id_type:  :uuid,
    )
  end

  def down
    execute %(DROP SCHEMA IF EXISTS "kiosk" CASCADE)
  end
end
