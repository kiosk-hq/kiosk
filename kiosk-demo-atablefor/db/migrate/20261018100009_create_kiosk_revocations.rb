# frozen_string_literal: true

# Migration 009 — create kiosk.revocations.
# Each agent's token revocation watermark, so a revoke or an unlink holds in
# every process and across restarts (RevocationStores::ActiveRecord, the default).
class CreateKioskRevocations < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute <<~'SQL'
      CREATE TABLE IF NOT EXISTS "kiosk".revocations (
        agent_id       uuid        PRIMARY KEY REFERENCES "kiosk".agents(id) ON DELETE CASCADE,
        revoked_before timestamptz NOT NULL
      );
    SQL
  end

  def down
    execute %(DROP TABLE IF EXISTS "kiosk".revocations)
  end
end
