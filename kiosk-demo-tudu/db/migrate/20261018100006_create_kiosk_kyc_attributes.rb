# frozen_string_literal: true

# Migration 006 — create kiosk.kyc_attributes.
# ONE ROW per NAMED ANONYMIZED boolean attribute a valid KYC attestation
# granted an agent (e.g. age_over_18, licence_a). Only the NAMES are stored —
# never the DOB, licence number, or any underlying document.
# There is no value column: the grant IS the row, so every gate is an EXISTS
# and no reader has to decide which spelling of `true` counts.
# Additive/opt-in: needed only if an Action gates on specific KYC attributes.
class CreateKioskKycAttributes < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    execute <<~'SQL'
      CREATE TABLE IF NOT EXISTS "kiosk".kyc_attributes (
        user_id    uuid NOT NULL REFERENCES "users"(id) ON DELETE CASCADE,
        name       text NOT NULL,
        granted_at timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (user_id, name)
      );

      CREATE TABLE IF NOT EXISTS "kiosk".kyc_requests (
        id          text PRIMARY KEY,
        user_id     uuid NOT NULL REFERENCES "users"(id) ON DELETE CASCADE,
        nonce       text NOT NULL,
        approved_at timestamptz,
        created_at  timestamptz NOT NULL DEFAULT now()
      );
      CREATE INDEX IF NOT EXISTS idx_kyc_requests_user_id ON "kiosk".kyc_requests (user_id, created_at);
    SQL
  end

  def down
    execute %(DROP TABLE IF EXISTS "kiosk".kyc_attributes)
  end
end
