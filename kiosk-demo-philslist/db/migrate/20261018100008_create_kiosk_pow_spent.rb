# frozen_string_literal: true

# Migration 008 — create kiosk.pow_spent.
# The spent proof-of-work challenge ids, so a proof is accepted once across
# every process and every deploy (PowSpentStores::ActiveRecord, the default).
class CreateKioskPowSpent < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute <<~'SQL'
      CREATE TABLE IF NOT EXISTS "kiosk".pow_spent (
        id         text        PRIMARY KEY,
        expires_at timestamptz NOT NULL
      );
      -- Supports the TTL sweep only; the PK above is what enforces
      -- single-use.
      CREATE INDEX IF NOT EXISTS idx_pow_spent_expires_at
        ON "kiosk".pow_spent (expires_at);
    SQL
  end

  def down
    execute %(DROP TABLE IF EXISTS "kiosk".pow_spent)
  end
end
