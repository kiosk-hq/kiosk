# frozen_string_literal: true

# Migration 011 — create kiosk.visits.
# The visits the operator records as fulfilled (Kiosk::Visit.record!), which
# lower the proof-of-work toll for a returning customer.
class CreateKioskVisits < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute <<~'SQL'
      CREATE TABLE IF NOT EXISTS "kiosk".visits (
        id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        user_id     uuid NOT NULL,
        value_cents bigint NOT NULL CHECK (value_cents >= 0),
        visited_at  timestamptz NOT NULL DEFAULT now()
      );
      CREATE INDEX IF NOT EXISTS idx_visits_user_id ON "kiosk".visits (user_id, visited_at);
    SQL
  end

  def down
    execute %(DROP TABLE IF EXISTS "kiosk".visits)
  end
end
