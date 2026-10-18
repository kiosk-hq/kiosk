# frozen_string_literal: true

# Migration 012 — create kiosk.refunds.
# The refunds of settled charges (Kiosk::Server::PaymentClaim#refund), which
# recent spend leaves out of the proof-of-work toll.
class CreateKioskRefunds < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute <<~'SQL'
      CREATE TABLE IF NOT EXISTS "kiosk".refunds (
        id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        settlement_id         uuid NOT NULL REFERENCES "kiosk".settlements(id) ON DELETE CASCADE,
        psp_reference         text NOT NULL UNIQUE,
        refunded_amount_cents bigint NOT NULL CHECK (refunded_amount_cents > 0),
        refunded_at           timestamptz NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_refunds_settlement_id ON "kiosk".refunds (settlement_id);
    SQL
  end

  def down
    execute %(DROP TABLE IF EXISTS "kiosk".refunds)
  end
end
